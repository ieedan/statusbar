import {
	cancel,
	confirm,
	intro,
	isCancel,
	log,
	note,
	outro,
	password,
	spinner,
	text,
} from '@clack/prompts';
import { Command, Option, program } from 'commander';
import { detect, resolveCommand } from 'package-manager-detector';
import { z } from 'zod';
import { spawn } from 'node:child_process';
import crypto from 'node:crypto';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const commonOptions = {
	fresh: new Option('-f, --fresh', 'Ignore any existing setup and start from scratch.'),
	cwd: new Option('--cwd <path>', 'The path to the project directory.').default(process.cwd()),
};

const setupSchema = z.object({
	fresh: z.boolean().default(false),
	cwd: z.string().default(process.cwd()),
});

type SetupOptions = z.infer<typeof setupSchema>;
type SetupMode = 'dev' | 'prod';

const draftSchema = z.object({
	mode: z.enum(['dev', 'prod']),
	step: z.string(),
	data: z.record(z.string(), z.unknown()).default({}),
});

type Draft = z.infer<typeof draftSchema>;

type StepContext = {
	options: SetupOptions;
	mode: SetupMode;
	data: Record<string, unknown>;
};

type Step = {
	name: string;
	run: (ctx: StepContext) => Promise<void>;
};

/** Thrown by a step when there is nothing left to do; ends the run cleanly. */
class StopSetup extends Error {}

/** Beside this file, so the `.gitignore` next to it covers the drafts. */
const TEMP_DIR = path.join(path.dirname(fileURLToPath(import.meta.url)), '.temp');

class DraftManager {
	constructor(private mode: SetupMode) {}

	path() {
		return path.join(TEMP_DIR, `setup-${this.mode}.json`);
	}

	read(): Draft | null {
		const file = this.path();
		if (!fs.existsSync(file)) return null;

		try {
			const parsed = draftSchema.parse(JSON.parse(fs.readFileSync(file, 'utf8')));
			return parsed.mode === this.mode ? parsed : null;
		} catch {
			fs.rmSync(file, { force: true });
			return null;
		}
	}

	write(draft: Draft) {
		const file = this.path();
		fs.mkdirSync(path.dirname(file), { recursive: true });
		// 0600: a half-finished run holds whatever the steps have collected, which
		// includes the certificate password and the Apple app-specific password.
		fs.writeFileSync(file, `${JSON.stringify(draft, null, '\t')}\n`, { mode: 0o600 });
	}

	discard() {
		fs.rmSync(this.path(), { force: true });
	}
}

/**
 * `Exclude<T, symbol>` rather than a bare `T`: since @clack/prompts 1.8 the
 * prompts return `string | typeof CANCEL_SYMBOL`, and a `unique symbol` will not
 * subtract out of `T | symbol` during inference — T comes back as the whole
 * union and the assertion narrows to nothing. This form holds on both.
 */
function exitIfCancelled<T>(value: T): asserts value is Exclude<T, symbol> {
	if (isCancel(value)) {
		cancel('Setup cancelled.');
		process.exit(0);
	}
}

function fail(message: string): never {
	cancel(message);
	process.exit(1);
}

type ExecResult = { code: number; stdout: string; stderr: string };

function exec(
	cmd: string,
	args: string[],
	opts: { cwd?: string; input?: string; env?: Record<string, string>; inherit?: boolean } = {}
): Promise<ExecResult> {
	return new Promise((resolve) => {
		const child = spawn(cmd, args, {
			cwd: opts.cwd,
			env: { ...process.env, ...opts.env },
			stdio: opts.inherit ? 'inherit' : ['pipe', 'pipe', 'pipe'],
		});
		let stdout = '';
		let stderr = '';
		child.stdout?.on('data', (chunk) => (stdout += chunk));
		child.stderr?.on('data', (chunk) => (stderr += chunk));
		child.on('error', (error) => resolve({ code: 127, stdout, stderr: error.message }));
		child.on('close', (code) => resolve({ code: code ?? 1, stdout, stderr }));
		child.stdin?.end(opts.input);
	});
}

async function has(cmd: string) {
	return (await exec('which', [cmd])).code === 0;
}

function lastLine(result: ExecResult) {
	const lines = `${result.stderr}\n${result.stdout}`
		.split('\n')
		.map((line) => line.trim())
		.filter(Boolean);
	return lines[lines.length - 1] ?? 'Unknown error.';
}

async function runSetup(
	mode: SetupMode,
	rawOptions: unknown,
	steps: Step[],
	done: string
) {
	const options = setupSchema.parse(rawOptions);
	const drafts = new DraftManager(mode);

	let startIndex = 0;
	let data: Record<string, unknown> = {};

	if (options.fresh) {
		drafts.discard();
	} else {
		const draft = drafts.read();
		const index = draft ? steps.findIndex((step) => step.name === draft.step) : -1;
		if (draft && index !== -1) {
			const resume = await confirm({
				message: `Would you like to resume your setup from step: ${draft.step}`,
			});
			exitIfCancelled(resume);
			if (resume) {
				startIndex = index;
				data = draft.data;
			} else {
				drafts.discard();
			}
		} else if (draft) {
			drafts.discard();
		}
	}

	const ctx: StepContext = { options, mode, data };

	try {
		for (let i = startIndex; i < steps.length; i++) {
			const step = steps[i];
			if (!step) continue;
			drafts.write({ mode, step: step.name, data: ctx.data });
			await step.run(ctx);
		}
	} catch (error) {
		if (error instanceof StopSetup) {
			drafts.discard();
			outro(error.message);
			return;
		}
		throw error;
	}

	drafts.discard();
	outro(done);
}

// ─── dev ────────────────────────────────────────────────────────────────────

const devSteps: Step[] = [
	{
		name: 'toolchain',
		run: async () => {
			if (process.platform !== 'darwin') fail('StatusBar only builds on macOS.');

			if (!(await has('swift'))) {
				log.info('Installing the Xcode command line tools.');
				await exec('xcode-select', ['--install'], { inherit: true });
				fail('Finish the install, then run setup again.');
			}
		},
	},
	{
		name: 'adapters',
		run: async ({ options }) => {
			const adapters = path.join(options.cwd, 'adapters');
			const pm = await detect({ cwd: adapters });
			const resolved = resolveCommand(pm?.agent ?? 'pnpm', 'install', []);
			if (!resolved) fail('Could not work out how to install the adapter dependencies.');

			log.step('Installing adapter dependencies');
			const install = await exec(resolved.command, resolved.args, {
				cwd: adapters,
				inherit: true,
			});
			if (install.code !== 0) fail('Installing the adapter dependencies failed.');

			log.step('Building adapters');
			const build = await exec('./scripts/build-adapters.sh', [], {
				cwd: options.cwd,
				inherit: true,
			});
			if (build.code !== 0) fail('Building the adapters failed.');
		},
	},
	{
		name: 'swift',
		run: async ({ options }) => {
			for (const dir of ['packages/StatusCore', 'apps/StatusBar']) {
				log.step(`Building ${dir}`);
				const build = await exec('swift', ['build'], {
					cwd: path.join(options.cwd, dir),
					inherit: true,
				});
				if (build.code !== 0) fail(`Building ${dir} failed.`);
			}
		},
	},
];

// ─── prod ───────────────────────────────────────────────────────────────────

/** The secrets .github/workflows/release.yml reads to sign + notarize. */
const SECRETS = [
	'MAC_CSC_LINK',
	'MAC_CSC_KEY_PASSWORD',
	'APPLE_ID',
	'APPLE_APP_SPECIFIC_PASSWORD',
	'APPLE_TEAM_ID',
] as const;

type ProdData = Partial<{
	repo: string;
	p12Path: string;
	p12Password: string;
	signer: string;
	teamId: string;
	appleId: string;
	appPassword: string;
}>;

/** Drag-and-drop into a terminal quotes or backslash-escapes the path. */
function normalizePath(input: string) {
	let value = input.trim().replace(/^(['"])(.*)\1$/, '$2').replace(/\\(.)/g, '$1');
	if (value.startsWith('~')) value = path.join(os.homedir(), value.slice(1));
	return path.resolve(value);
}

/** Imports the .p12 the same way CI does, into a keychain that is deleted after. */
async function inspectCertificate(file: string, filePassword: string) {
	const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'statusbar-cert-'));
	const keychain = path.join(dir, 'check.keychain-db');

	try {
		const create = await exec('security', ['create-keychain', '-p', crypto.randomUUID(), keychain]);
		if (create.code !== 0) return { error: lastLine(create) };

		const imported = await exec('security', [
			'import',
			file,
			'-k',
			keychain,
			'-P',
			filePassword,
			'-T',
			'/usr/bin/codesign',
		]);
		if (imported.code !== 0) return { error: 'Wrong password, or not a valid .p12 file.' };

		const identities = await exec('security', ['find-identity', '-v', '-p', 'codesigning', keychain]);
		const match = identities.stdout.match(/"(Developer ID Application: .+? \(([A-Z0-9]{10})\))"/);
		if (!match?.[1] || !match[2]) {
			return { error: 'That file has no valid "Developer ID Application" certificate.' };
		}

		return { signer: match[1], teamId: match[2] };
	} finally {
		await exec('security', ['delete-keychain', keychain]);
		fs.rmSync(dir, { recursive: true, force: true });
	}
}

const prodSteps: Step[] = [
	{
		name: 'github',
		run: async (ctx) => {
			const data = ctx.data as ProdData;

			if (!(await has('gh'))) {
				if (!(await has('brew'))) {
					fail('Install the GitHub CLI from https://cli.github.com, then run setup again.');
				}
				const install = await confirm({ message: 'Install the GitHub CLI with Homebrew?' });
				exitIfCancelled(install);
				if (!install) fail('The GitHub CLI is needed to set the secrets.');

				const brew = await exec('brew', ['install', 'gh'], { inherit: true });
				if (brew.code !== 0) fail('Homebrew could not install the GitHub CLI.');
			}

			if ((await exec('gh', ['auth', 'status'])).code !== 0) {
				log.info('Sign in to GitHub.');
				const login = await exec('gh', ['auth', 'login'], { inherit: true });
				if (login.code !== 0) fail('GitHub sign-in failed.');
			}

			const repo = await exec(
				'gh',
				['repo', 'view', '--json', 'nameWithOwner', '-q', '.nameWithOwner'],
				{ cwd: ctx.options.cwd }
			);
			if (repo.code !== 0) fail('Could not find the GitHub repository for this project.');
			data.repo = repo.stdout.trim();

			const existing = await exec('gh', [
				'secret',
				'list',
				'--repo',
				data.repo,
				'--json',
				'name',
				'-q',
				'.[].name',
			]);
			const set = existing.stdout.split('\n').filter((name) => SECRETS.some((s) => s === name));

			if (set.length === SECRETS.length) {
				const replace = await confirm({
					message: `The signing secrets are already set on ${data.repo}. Replace them?`,
					initialValue: false,
				});
				exitIfCancelled(replace);
				if (!replace) throw new StopSetup('Nothing to do.');
			}
		},
	},
	{
		name: 'certificate',
		run: async (ctx) => {
			const data = ctx.data as ProdData;

			const local = await exec('security', ['find-identity', '-v', '-p', 'codesigning']);
			const localSigner = local.stdout.match(/"(Developer ID Application: .+?)"/)?.[1];

			if (localSigner) {
				log.success(`Found ${localSigner} in your keychain.`);
			} else {
				note(
					[
						'Open Xcode → Settings → Accounts',
						'Select your team → Manage Certificates',
						'Click + → Developer ID Application',
					].join('\n'),
					'Create the certificate'
				);
			}

			await exec('open', ['-a', 'Keychain Access']);
			note(
				[
					'Keychain Access → login → My Certificates',
					localSigner ? `Right-click "${localSigner}"` : 'Right-click "Developer ID Application: …"',
					'Export… → save as .p12 and set a password',
				].join('\n'),
				'Export the certificate'
			);

			for (;;) {
				const file = await text({
					message: 'Path to the exported .p12 (drag it in):',
					initialValue: data.p12Path,
					validate: (value) => {
						const resolved = normalizePath(value ?? '');
						return fs.existsSync(resolved) && fs.statSync(resolved).isFile()
							? undefined
							: 'File not found.';
					},
				});
				exitIfCancelled(file);

				const filePassword = await password({ message: 'Password you set for it:' });
				exitIfCancelled(filePassword);

				const s = spinner();
				s.start('Checking the certificate');
				const result = await inspectCertificate(normalizePath(file), filePassword);

				if ('error' in result) {
					s.error(result.error ?? 'Invalid certificate.');
					data.p12Path = file;
					continue;
				}

				s.stop(`${result.signer}`);
				data.p12Path = normalizePath(file);
				data.p12Password = filePassword;
				data.signer = result.signer;
				data.teamId = result.teamId;
				break;
			}
		},
	},
	{
		name: 'notarization',
		run: async (ctx) => {
			const data = ctx.data as ProdData;
			if (!data.teamId) fail('The certificate step did not finish. Run setup again with --fresh.');

			note(
				[
					'Open https://account.apple.com',
					'Sign-In and Security → App-Specific Passwords → +',
					'Name it "statusbar" and copy the password',
				].join('\n'),
				'Create an app-specific password'
			);

			for (;;) {
				const appleId = await text({
					message: 'Apple ID email (the one on your developer account):',
					initialValue: data.appleId,
					validate: (value) => (value?.includes('@') ? undefined : 'Enter an email address.'),
				});
				exitIfCancelled(appleId);

				const appPassword = await password({
					message: 'App-specific password (xxxx-xxxx-xxxx-xxxx):',
					validate: (value) =>
						/^[a-z]{4}(-[a-z]{4}){3}$/.test(value ?? '')
							? undefined
							: 'It looks like xxxx-xxxx-xxxx-xxxx, not your Apple ID password.',
				});
				exitIfCancelled(appPassword);

				const s = spinner();
				s.start('Checking with Apple');
				const check = await exec(
					'xcrun',
					[
						'notarytool',
						'history',
						'--apple-id',
						appleId,
						'--team-id',
						data.teamId,
						// notarytool has no way to read this from the environment or stdin.
						'--password',
						appPassword,
					]
				);

				if (check.code !== 0) {
					s.error('Apple rejected those credentials.');
					log.error(lastLine(check));
					data.appleId = appleId;
					continue;
				}

				s.stop('Apple accepted the credentials.');
				data.appleId = appleId;
				data.appPassword = appPassword;
				break;
			}
		},
	},
	{
		name: 'publish',
		run: async (ctx) => {
			const data = ctx.data as ProdData;
			const { repo, p12Path, p12Password, signer, teamId, appleId, appPassword } = data;
			if (!repo || !p12Path || !p12Password || !signer || !teamId || !appleId || !appPassword) {
				fail('A previous step did not finish. Run setup again with --fresh.');
			}

			note(
				[
					`Repository   ${repo}`,
					`Certificate  ${signer}`,
					`Apple ID     ${appleId}`,
					`Team ID      ${teamId}`,
				].join('\n'),
				'Ready to set secrets'
			);

			const proceed = await confirm({
				message: `Set ${SECRETS.length} secrets on ${repo}?`,
			});
			exitIfCancelled(proceed);
			if (!proceed) throw new StopSetup('Nothing was changed.');

			const values: Record<(typeof SECRETS)[number], string> = {
				MAC_CSC_LINK: fs.readFileSync(p12Path).toString('base64'),
				MAC_CSC_KEY_PASSWORD: p12Password,
				APPLE_ID: appleId,
				APPLE_APP_SPECIFIC_PASSWORD: appPassword,
				APPLE_TEAM_ID: teamId,
			};

			const s = spinner();
			for (const name of SECRETS) {
				s.start(`Setting ${name}`);
				// Via stdin, so the value never shows up in the process list.
				const result = await exec('gh', ['secret', 'set', name, '--repo', repo], {
					input: values[name],
				});
				if (result.code !== 0) {
					s.error(`Could not set ${name}.`);
					fail(lastLine(result));
				}
				s.stop(`Set ${name}`);
			}

			const remove = await confirm({ message: 'Delete the exported .p12 now that it is uploaded?' });
			exitIfCancelled(remove);
			if (remove) fs.rmSync(p12Path, { force: true });
		},
	},
];

// ─── commands ───────────────────────────────────────────────────────────────

const dev = new Command('dev')
	.description('Install dependencies and build everything to run StatusBar from source.')
	.addOption(commonOptions.fresh)
	.addOption(commonOptions.cwd)
	.action(async (rawOptions) => {
		intro('StatusBar · dev setup');
		await runSetup('dev', rawOptions, devSteps, 'Done. Start the app with `make run`.');
	});

const prod = new Command('prod')
	.description('Set the Apple signing + notarization secrets so releases ship signed.')
	.addOption(commonOptions.fresh)
	.addOption(commonOptions.cwd)
	.action(async (rawOptions) => {
		intro('StatusBar · release signing setup');
		await runSetup(
			'prod',
			rawOptions,
			prodSteps,
			'Done. The next release built from main will be signed and notarized.'
		);
	});

const cli = program
	.name('setup')
	.description('Setup the project for development or production.')
	.addCommand(dev)
	.addCommand(prod);

cli.parse();
