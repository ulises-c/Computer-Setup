import os
from pathlib import Path
import shutil
import subprocess
import sys
import json
import shlex
import tempfile
import unittest

HERE = Path(__file__).resolve().parent


class RuntimeTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.home = Path(self.temp.name) / 'home space%'
        self.home.mkdir()
        self.runtime = self.home / 'checkout space%/wiki'
        shutil.copytree(HERE, self.runtime, ignore=shutil.ignore_patterns('__pycache__'))
        portal = self.runtime.parent / 'portal'
        portal.mkdir()
        (portal / 'sync.py').write_text(
            'import json, os, sys\n'
            'if "--help" in sys.argv: print("publish-wiki")\n'
            'else:\n'
            ' with open(os.environ["CALL_LOG"], "a") as out:\n'
            '  out.write(json.dumps([sys.argv[1:], os.environ.get("RS_SDK_WIKI_DIR"), os.environ.get("BOTTING_DIR")]) + "\\n")\n')
        self.bin = self.home / '.local/bin'
        self.bin.mkdir(parents=True)
        self.log = self.home / 'calls'
        self.env = dict(os.environ, HOME=str(self.home), PATH=f'{self.bin}:' + os.environ['PATH'], CALL_LOG=str(self.log))
        site = self.home / 'python-fixtures'
        site.mkdir()
        (site / 'sitecustomize.py').write_text(
            'import os, shutil\n'
            '_which = shutil.which\n'
            'def fixture_which(command, mode=os.F_OK | os.X_OK, path=None):\n'
            ' if command in ("bun", "git-lfs"): path = os.path.join(os.environ["HOME"], ".local/bin")\n'
            ' return _which(command, mode=mode, path=path)\n'
            'shutil.which = fixture_which\n')
        self.env['PYTHONPATH'] = str(site)
        for name, body in {
            'systemctl': 'printf "%s\\n" "$*" >> "$CALL_LOG"',
            'loginctl': 'printf "%s\\n" "${TEST_LINGER:-yes}"',
            'bun': 'exit 0', 'git-lfs': 'exit 0',
        }.items():
            path = self.bin / name
            path.write_text('#!/bin/sh\n' + body + '\n')
            path.chmod(0o755)
        self.wiki = self.home / 'forgejo/2004Scape-Wiki'
        (self.wiki / 'bin').mkdir(parents=True)
        (self.wiki / 'bin/wiki').write_text('#!/bin/sh\nprintf "%s\\n" "$*" >> "$CALL_LOG"\n')
        (self.wiki / 'bin/wiki').chmod(0o755)
        self.ref = self.home / 'github/rs-sdk/wiki'
        self.ref.mkdir(parents=True)
        (self.ref / 'item.md').write_text('# Item\n')
        self.bot = self.home / 'forgejo/2004Scape-Botting'
        (self.bot / 'observations').mkdir(parents=True)
        (self.bot / 'learnings').mkdir()
        (self.bot / 'learnings/guide.md').write_text('# Guide\n')
        for name in ('items', 'locs', 'npcs', 'ground-items', 'shops'):
            (self.bot / f'observations/{name}.tsv').write_text('id\tname\n')

    def run_install(self, *args):
        return subprocess.run(['bash', str(self.runtime / 'install.sh'), *args], env=self.env, text=True, capture_output=True)

    def test_runtime_binary_lookup_ignores_unrelated_path_entries(self):
        fallback = self.home / 'fallback-bin'
        fallback.mkdir()
        self.env['PATH'] += os.pathsep + str(fallback)
        for name in ('bun', 'git-lfs'):
            with self.subTest(binary=name):
                executable = fallback / name
                executable.write_text('#!/bin/sh\nexit 0\n')
                executable.chmod(0o755)
                (self.bin / name).unlink()
                result = subprocess.run(
                    [sys.executable, '-c', 'import shutil, sys; print(shutil.which(sys.argv[1]))', name],
                    env=self.env, text=True, capture_output=True, check=True)
                self.assertEqual(result.stdout.strip(), 'None')

    def test_prerequisites_fail_closed_without_writes(self):
        paths = [self.bin / 'bun', self.bin / 'git-lfs', self.wiki / 'bin/wiki',
                 self.ref / 'item.md', self.bot / 'learnings/guide.md',
                 *sorted(p for p in (self.bot / 'observations').glob('*.tsv') if p.name != 'shops.tsv')]
        for path in paths:
            with self.subTest(prerequisite=path.name):
                saved = path.with_suffix('.disabled')
                path.rename(saved)
                try:
                    result = self.run_install()
                    self.assertNotEqual(result.returncode, 0, result.stdout)
                    self.assertIn('error:', result.stderr)
                    self.assertFalse((self.home / '.config/systemd').exists())
                    self.assertFalse(self.log.exists())
                finally:
                    saved.rename(path)

    def test_linger_required(self):
        self.env['TEST_LINGER'] = 'no'
        result = self.run_install()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('Linger=yes', result.stderr)
        self.assertFalse((self.home / '.config/systemd').exists())
        self.assertFalse(self.log.exists())

    def test_no_start_renders_without_enabling(self):
        result = self.run_install('--no-start')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue((self.home / '.config/systemd/user/rs-sdk-wiki-publish.timer').is_file())
        self.assertEqual(self.log.read_text().splitlines(), ['--user daemon-reload'])

    def test_dry_run_makes_no_writes_or_systemctl_calls(self):
        before = sorted(str(p.relative_to(self.home)) for p in self.home.rglob('*'))
        result = self.run_install('--dry-run')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('rs-sdk-wiki-publish.timer', result.stdout)
        self.assertIn('daemon-reload', result.stdout)
        self.assertIn('enable --now', result.stdout)
        self.assertEqual(before, sorted(str(p.relative_to(self.home)) for p in self.home.rglob('*')))

    def test_publication_leaves_downloads_to_the_managed_drain_service(self):
        (self.runtime.parent / 'portal/sync.py').write_text(
            'import os\nassert os.environ.get("WIKI_AUTO_IMAGES") == "0"\n')
        result = subprocess.run([sys.executable, '-B', str(self.runtime / 'runtime.py'), 'publish'],
                                env=self.env, text=True, capture_output=True)
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_runtime_executes_canonical_commands_and_rechecks_inputs(self):
        for action in ('drain', 'publish'):
            result = subprocess.run([sys.executable, '-B', str(self.runtime / 'runtime.py'), action],
                                    env=self.env, text=True, capture_output=True)
            self.assertEqual(result.returncode, 0, result.stderr)
        lines = self.log.read_text().splitlines()
        self.assertEqual(lines[0], 'downloads --drain')
        published = json.loads(lines[1])
        self.assertEqual(published, [['publish-wiki', '--wiki-root', str(self.wiki), '--target',
                                     str(self.home / '.local/share/rs-sdk-portal/data'), '--curated'], str(self.ref), str(self.bot)])
        self.log.unlink()
        (self.bot / 'observations/items.tsv').unlink()
        result = subprocess.run([sys.executable, '-B', str(self.runtime / 'runtime.py'), 'publish'],
                                env=self.env, text=True, capture_output=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(self.log.exists())

    def test_private_canonical_json_selects_timer_inputs(self):
        ref = self.home / 'staged/reference'
        bot = self.home / 'staged/bot'
        ref.parent.mkdir()
        self.ref.rename(ref)
        self.bot.rename(bot)
        selected = self.home / 'selected-wiki'
        self.wiki.rename(selected)
        self.wiki = selected
        (selected / 'data').mkdir()
        config = selected / 'data/inputs.json'
        alias = self.home / 'bot-alias'
        alias.symlink_to(bot)
        config.write_text(json.dumps({'RS_SDK_WIKI_DIR': '~/staged/reference', 'BOTTING_DIR': str(alias)}))
        config.chmod(0o600)
        self.env.update(RS_SDK_WIKI_DIR='/wrong', BOTTING_DIR='/wrong')
        result = self.run_install('--wiki-root', str(selected), '--no-start')
        self.assertEqual(result.returncode, 0, result.stderr)
        service = (self.home / '.config/systemd/user/rs-sdk-wiki-publish.service').read_text()
        self.assertNotIn('--env-file', service)
        self.assertIn('--wiki-root', service)
        command = shlex.split(next(line.split('=', 1)[1] for line in service.splitlines() if line.startswith('ExecStart=')))
        command = [word.replace('%%', '%').replace('$$', '$') for word in command]
        published = subprocess.run(command, env=self.env, text=True, capture_output=True)
        self.assertEqual(published.returncode, 0, published.stderr)
        payload = json.loads(self.log.read_text().splitlines()[-1])
        self.assertEqual(payload[1:], [str(ref), str(bot)])
        next_bot = self.home / 'next-bot'
        shutil.copytree(bot, next_bot)
        alias.unlink()
        alias.symlink_to(next_bot)
        published = subprocess.run(command, env=self.env, text=True, capture_output=True)
        self.assertEqual(published.returncode, 0, published.stderr)
        self.assertEqual(json.loads(self.log.read_text().splitlines()[-1])[2], str(next_bot))
        self.assertEqual(json.loads(config.read_text())['BOTTING_DIR'], str(alias))

    def test_invalid_canonical_config_fails_before_commands(self):
        config = self.wiki / 'data/inputs.json'
        config.parent.mkdir()
        for value in ['{', 'null', '[]', '7', '{"WIKI_DB":"/bad"}', '{"BOTTING_DIR":null}',
                      '{"BOTTING_DIR":"relative"}', '{"BOTTING_DIR":"~other/path"}',
                      '{"BOTTING_DIR":"/missing"}', json.dumps({'BOTTING_DIR': '/bad\u0085path'}),
                      json.dumps({'BOTTING_DIR\n': '/bad'})]:
            with self.subTest(value=value):
                config.write_text(value)
                config.chmod(0o600)
                result = self.run_install()
                self.assertNotEqual(result.returncode, 0)
                self.assertIn('error:', result.stderr)
                self.assertFalse(self.log.exists())
                self.assertFalse((self.home / '.config/systemd').exists())
        for mode in (0o644, 0o400, 0o700):
            config.chmod(0o600)
            config.write_text('{}')
            config.chmod(mode)
            self.assertNotEqual(self.run_install().returncode, 0)
        config.unlink()
        config.symlink_to(self.home / 'missing-config')
        self.assertNotEqual(self.run_install().returncode, 0)

    def test_optional_shop_observations_not_required(self):
        (self.bot / 'observations/shops.tsv').unlink()
        result = self.run_install('--no-start')
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_runtime_pins_atomic_input_generation(self):
        generation = self.home / 'bot-generation'
        self.bot.rename(generation)
        self.bot.symlink_to(generation)
        result = subprocess.run([sys.executable, '-B', str(self.runtime / 'runtime.py'), 'publish'],
                                env=self.env, text=True, capture_output=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        payload = json.loads(self.log.read_text().splitlines()[-1])
        self.assertEqual(payload[2], str(generation))

    def test_portal_publisher_support_required(self):
        (self.runtime.parent / 'portal/sync.py').write_text('print("push receive")\n')
        result = self.run_install()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('publish-wiki', result.stderr)
        self.assertFalse((self.home / '.config/systemd').exists())

    def test_unit_quoting_round_trips_and_rejects_control_characters(self):
        import runpy
        quote = runpy.run_path(str(self.runtime / 'runtime.py'))['unit_quote']
        value = 'path space%$"\\tail'
        rendered = quote(value, expand_dollars=True)
        decoded = shlex.split(rendered)[0].replace('%%', '%').replace('$$', '$')
        self.assertEqual(decoded, value)
        self.assertIn('$', quote(value))
        self.assertNotIn('$$', quote(value))
        with self.assertRaises(ValueError):
            quote('bad\npath')

    def test_inherited_database_override_is_rejected(self):
        self.env['WIKI_DB'] = str(self.home / 'wrong.sqlite')
        result = self.run_install()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('WIKI_DB', result.stderr)
        self.assertFalse(self.log.exists())

    def test_unhydrated_lfs_curated_input_is_rejected(self):
        (self.ref / 'item.md').write_text('version https://git-lfs.github.com/spec/v1\noid sha256:fixture\nsize 1\n')
        result = self.run_install()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('LFS', result.stderr)
        self.assertFalse(self.log.exists())

    def test_install_renders_and_enables_only_wiki_timers(self):
        result = self.run_install()
        self.assertEqual(result.returncode, 0, result.stderr)
        units = self.home / '.config/systemd/user'
        for action in ('drain', 'publish'):
            service = (units / f'rs-sdk-wiki-{action}.service').read_text()
            timer = (units / f'rs-sdk-wiki-{action}.timer').read_text()
            self.assertIn('Type=oneshot', service)
            self.assertIn('TimeoutStartSec=infinity', service)
            self.assertIn('%%', service)
            self.assertIn('.bun/bin', service)
            self.assertIn('.local/bin', service)
            self.assertIn('Persistent=true', timer)
            self.assertIn('OnCalendar=', timer)
        self.assertEqual(self.log.read_text().splitlines(), [
            '--user daemon-reload',
            '--user enable --now rs-sdk-wiki-drain.timer rs-sdk-wiki-publish.timer',
        ])


if __name__ == '__main__':
    unittest.main()
