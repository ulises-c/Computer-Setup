from pathlib import Path
import json
import shutil
import sqlite3
import subprocess
import sys
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]
PAGES = ROOT / "rs-sdk/hiscore-pages.js"
PRUNE = ROOT / "rs-sdk/hiscore-prune.js"
FIX = ROOT / "rs-sdk/fix-hiscore-levels.py"
HISCORES = "server/engine/src/web/pages/hiscores.ts"
LOGIN = "server/engine/src/server/login/LoginServer.ts"
# The patch scripts are plain CommonJS; bun runs them too (the game server has no node).
JS = shutil.which("node") or shutil.which("bun")
BUN = shutil.which("bun")

# The anchors hiscore-pages.js needs, as upstream rs-sdk (b565f2d, 1599b86) writes them.
HISCORES_TS = """export async function handleHiscoresPage(url: URL): Promise<Response | null> {
    const playerSearch = url.searchParams.get('player')?.toLowerCase().trim() || '';
    const rankSearch = tryParseInt(url.searchParams.get('rank'), -1);
    if (category === 0) {
        const startRank = rankSearch > 0 ? rankSearch - 1 : 0;
        rows = allResults.slice(startRank, startRank + 21).map((r, i) => ({
        }));
    } else {
        if (skillName) {
            const startRank = rankSearch > 0 ? rankSearch - 1 : 0;
            rows = allResults.slice(startRank, startRank + 21).map((r, i) => ({
            }));
        }
    }
    const nameCol = rows.map(r => `<a href="/hiscores/player/${encodeURIComponent(r.username)}?profile=${profile}" class="c">${escapeHtml(r.username)}</a><br>`).join('\\n');
    const html = `
                                </table>
                            </center>
                        </td>
                    </tr>
                </table>

                <br>

                <!-- Search boxes -->
                                Rank: ${searchedPlayer.rank} |
`;
}
"""

LOGIN_TS = """    for (let stat = 0; stat < player.stats.length; stat++) {
        if (!PlayerStatEnabled[stat]) {
            continue;
        }

        if (player.baseLevels[stat] >= 15) {
            const hiscoreType = stat + 1;
            const reached = player.levelPlaytime[stat] || player.playtime;
        }
    }
"""


@unittest.skipUnless(JS, "needs node or bun")
class HiscorePatchTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        for name, text in ((HISCORES, HISCORES_TS), (LOGIN, LOGIN_TS)):
            (self.root / name).parent.mkdir(parents=True, exist_ok=True)
            (self.root / name).write_text(text)

    def run_patch(self, script):
        return subprocess.run([JS, str(script), str(self.root)], capture_output=True, text=True)

    def test_pager_is_added_under_the_ranked_table_and_rerun_is_a_no_op(self):
        result = self.run_patch(PAGES)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("Hiscore list pager verified", result.stdout)
        text = (self.root / HISCORES).read_text()
        self.assertEqual(text.count("pageStart = startRank;"), 2)
        self.assertEqual(text.count("rankedTotal = allResults.length;"), 2)
        self.assertLess(text.index("${hiscorePager("), text.index("<!-- Search boxes -->"))
        self.assertIn("'c yellow' : 'c'", text)
        self.assertIn("Math.max(1, searchedPlayer.rank - 10)", text)
        result = self.run_patch(PAGES)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual((self.root / HISCORES).read_text(), text)

    @unittest.skipUnless(BUN, "needs bun to run the TypeScript helpers")
    def test_pager_links_walk_twenty_one_ranks_and_disable_the_ends(self):
        self.assertEqual(self.run_patch(PAGES).returncode, 0)
        text = (self.root / HISCORES).read_text()
        start = text.index("// computer-setup: hiscore page navigation")
        helpers = text[start:text.index("export async function handleHiscoresPage")]
        probe = self.root / "probe.ts"
        probe.write_text(helpers + """
const links = (html: string) => [...html.matchAll(/<a href="([^"]+)"[^>]*>([^<]+)</g)].map(m => [m[2].replace(/&#9650;|&#9660;/g, '').trim(), m[1]]);
const off = (html: string) => [...html.matchAll(/aria-disabled="true">([^<]+)</g)].map(m => m[1].replace(/&#9650;|&#9660;/g, '').trim());
const page = (start: number, total: number, player = '') => {
    const html = hiscorePager(9, 'main', start, total, player);
    return { links: links(html), off: off(html), range: (html.match(/font-size:11px">([^<]+)</) ?? [])[1] ?? null };
};
console.log(JSON.stringify({
    first: page(0, 73), second: page(21, 73), last: page(63, 73), past: page(100, 73),
    single: page(0, 5), named: page(21, 73, 'player one'), empty: hiscorePager(9, 'main', 0, 0, ''),
}));
""")
        result = subprocess.run([BUN, str(probe)], capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        out = json.loads(result.stdout)
        href = "/hiscores?category=9&rank={}&profile=main"
        self.assertEqual(out["first"], {"links": [["Next", href.format(22)]], "off": ["Top", "Prev"], "range": "Ranks 1&ndash;21 of 73"})
        self.assertEqual(out["second"]["links"], [["Top", href.format(1)], ["Prev", href.format(1)], ["Next", href.format(43)]])
        self.assertEqual(out["last"], {"links": [["Top", href.format(1)], ["Prev", href.format(43)]], "off": ["Next"], "range": "Ranks 64&ndash;73 of 73"})
        self.assertEqual(out["past"]["links"], [["Top", href.format(1)], ["Prev", href.format(53)]])
        self.assertEqual(out["past"]["range"], "73 ranked")
        self.assertEqual(out["single"]["off"], ["Top", "Prev", "Next"])
        self.assertEqual(out["named"]["links"][2], ["Next", href.format(43) + "&player=player%20one"])
        self.assertEqual(out["empty"], "")

    def test_unknown_list_page_fails_without_changing_it(self):
        path = self.root / HISCORES
        path.write_text(HISCORES_TS.replace("startRank + 21", "startRank + 25"))
        before = path.read_text()
        result = self.run_patch(PAGES)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Unexpected hiscore list page", result.stderr)
        self.assertEqual(path.read_text(), before)

    def test_rows_below_fifteen_are_deleted_and_rerun_is_a_no_op(self):
        result = self.run_patch(PRUNE)
        self.assertEqual(result.returncode, 0, result.stderr)
        text = (self.root / LOGIN).read_text()
        self.assertNotIn(">= 15", text)
        branch = text.split("if (player.baseLevels[stat] < 15) {", 1)[1].split("} else {", 1)[0]
        self.assertIn("db.deleteFrom('hiscore').where('account_id', '=', account.id).where('type', '=', stat + 1).where('profile', '=', profile).execute()", branch)
        self.assertIn("} else {\n            const hiscoreType = stat + 1;\n            const reached", text)
        self.assertEqual(self.run_patch(PRUNE).returncode, 0)
        self.assertEqual((self.root / LOGIN).read_text(), text)

    def test_unknown_level_gate_fails_without_changing_it(self):
        path = self.root / LOGIN
        path.write_text(LOGIN_TS.replace(">= 15", ">= 10"))
        before = path.read_text()
        result = self.run_patch(PRUNE)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Unexpected hiscore level gate", result.stderr)
        self.assertEqual(path.read_text(), before)


class HiscoreLevelFixTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.dir = Path(self.tmp.name)
        self.db = self.dir / "db.sqlite"
        con = sqlite3.connect(self.db)
        con.executescript("""
            CREATE TABLE account (id INTEGER PRIMARY KEY, username TEXT, password TEXT);
            CREATE TABLE hiscore (account_id INT, profile TEXT, type INT, level INT, value INT, playtime INT DEFAULT 0,
                PRIMARY KEY (profile, type, account_id));
            CREATE TABLE hiscore_large (account_id INT, profile TEXT, type INT, level INT, value INT, playtime INT DEFAULT 0);
            INSERT INTO account VALUES (1, 'player_one', 'x'), (2, 'bot_a', 'x');
            -- 22,892.5 xp: level 35 on the original curve, 45 on the level/10 one
            INSERT INTO hiscore VALUES (1, 'main', 9, 45, 228925, 7);
            -- already right: 13,034,431 xp is level 99
            INSERT INTO hiscore VALUES (1, 'main', 2, 99, 130344310, 5);
            -- 2,000 xp is level 13 on the original curve: the row must go
            INSERT INTO hiscore VALUES (2, 'main', 11, 21, 20000, 3);
            -- quest points are not XP
            INSERT INTO hiscore VALUES (2, 'main', 100, 5, 5, 3);
            INSERT INTO hiscore_large VALUES (1, 'main', 0, 400, 999, 1);
        """)
        con.commit()
        con.close()

    def run_fix(self, *args):
        return subprocess.run([sys.executable, str(FIX), "--db", str(self.db), "--backup-dir", str(self.dir / "backups"), *args],
                              capture_output=True, text=True)

    def rows(self):
        con = sqlite3.connect(self.db)
        rows = con.execute("SELECT account_id, type, level, value, playtime FROM hiscore ORDER BY account_id, type").fetchall()
        con.close()
        return rows

    def test_level_table_matches_the_original_curve(self):
        import importlib.util
        spec = importlib.util.spec_from_file_location("fix_hiscore_levels", FIX)
        fix = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(fix)
        self.assertEqual([fix.level_for(v) for v in (0, 829, 830, 11540, 228925, 130344309, 130344310, 2_000_000_000)],
                         [1, 1, 2, 10, 35, 98, 99, 99])

    def test_dry_run_reports_the_plan_and_changes_nothing(self):
        before = self.rows()
        result = self.run_fix()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("before: skill_rows=3, skill_accounts=2, off_curve_rows=1, below_15_rows=1", result.stdout)
        self.assertIn("relevel player_one/main type 9: xp 22,892.5 level 45 -> 35", result.stdout)
        self.assertIn("delete bot_a/main type 11: xp 2,000.0 level 21 -> 13", result.stdout)
        self.assertIn("after (dry run, expected): skill_rows=2", result.stdout)
        self.assertNotIn("password", result.stdout)
        self.assertEqual(self.rows(), before)
        self.assertFalse((self.dir / "backups").exists())

    def test_apply_backs_up_then_relevels_and_deletes(self):
        result = self.run_fix("--apply")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("applied", result.stdout)
        self.assertIn("after: skill_rows=2, skill_accounts=1, off_curve_rows=0, below_15_rows=0, other_hiscore_rows=1, hiscore_large_rows=1", result.stdout)
        self.assertEqual(self.rows(), [(1, 2, 99, 130344310, 5), (1, 9, 35, 228925, 7), (2, 100, 5, 5, 3)])
        backups = list((self.dir / "backups").glob("hiscore-fix-*.sqlite"))
        self.assertEqual(len(backups), 1)
        self.assertFalse(Path(f"{backups[0]}-wal").exists())
        con = sqlite3.connect(backups[0])
        self.assertEqual(con.execute("SELECT level FROM hiscore WHERE type = 9").fetchone(), (45,))
        con.close()
        self.assertEqual(len(list((self.dir / "backups").glob("hiscore-fix-*.raw/db.sqlite"))), 1)
        again = self.run_fix("--apply")
        self.assertEqual(again.returncode, 0, again.stderr)
        self.assertIn("plan: relevel 0 rows, delete 0 rows", again.stdout)
        self.assertEqual(self.rows(), [(1, 2, 99, 130344310, 5), (1, 9, 35, 228925, 7), (2, 100, 5, 5, 3)])


if __name__ == "__main__":
    unittest.main()
