const fs = require('node:fs');
const path = require('node:path');

// Prev/Next navigation for the ranked hiscore lists (Overall, each skill, Quest Points).
// The Equipment and Bank boards are fixed top-50 lists and Lava Maze Runite three top-10
// lists, so they get no pager.
const root = process.argv[2] ?? '/opt';
const name = 'server/engine/src/web/pages/hiscores.ts';
const filename = path.join(root, name);
const text = fs.readFileSync(filename, 'utf8');
const marker = 'computer-setup: hiscore page navigation';

const helpers = `// ${marker} (linux-game-server/rs-sdk/hiscore-pages.js).
// The pager walks the ranked list one page at a time, the same 21 rows the rank search shows,
// keeping the category, profile and searched name; the ends are shown disabled.
const HISCORES_PAGE_SIZE = 21;

function hiscorePageHref(category: number, profile: string, rank: number, player: string): string {
    return \`/hiscores?category=\${category}&rank=\${rank}&profile=\${profile}\${player ? \`&player=\${encodeURIComponent(player)}\` : ''}\`;
}

function hiscorePager(category: number, profile: string, start: number, total: number, player: string): string {
    if (total <= 0) return '';
    const size = HISCORES_PAGE_SIZE;
    const button = (label: string, title: string, rank: number | null) =>
        rank === null
            ? \`<span style="color:#7d6f5d;font-weight:bold" aria-disabled="true">\${label}</span>\`
            : \`<a href="\${hiscorePageHref(category, profile, rank, player)}" class="c" style="color:#FFE139;font-weight:bold" title="\${title}">\${label}</a>\`;
    // a rank search past the end has an empty page: Prev goes back to the last full page
    const prevStart = start >= total ? Math.max(0, total - size) : Math.max(0, start - size);
    const top = button('&#9650;&#9650; Top', 'Rank 1', start > 0 ? 1 : null);
    const prev = button('&#9650; Prev', \`Ranks \${prevStart + 1}+\`, start > 0 ? prevStart + 1 : null);
    const next = button('Next &#9660;', \`Ranks \${start + size + 1}+\`, start + size < total ? start + size + 1 : null);
    const range = start < total ? \`Ranks \${start + 1}&ndash;\${Math.min(start + size, total)} of \${total}\` : \`\${total} ranked\`;
    return \`
                                <!-- Page navigation -->
                                <table class="hiscore-pager" width="300" bgcolor="black" cellpadding="4" style="margin-top:6px">
                                    <tr>
                                        <td class="b" bgcolor="#474747" background="/img/stoneback.gif">
                                            <table width="100%" cellspacing="0" cellpadding="0">
                                                <tr>
                                                    <td align="left">\${top}&nbsp;&nbsp;\${prev}</td>
                                                    <td align="center" style="font-size:11px">\${range}</td>
                                                    <td align="right">\${next}</td>
                                                </tr>
                                            </table>
                                        </td>
                                    </tr>
                                </table>\`;
}

`;

const nameColOld = "    const nameCol = rows.map(r => `<a href=\"/hiscores/player/${encodeURIComponent(r.username)}?profile=${profile}\" class=\"c\">${escapeHtml(r.username)}</a><br>`).join('\\n');";
const nameColNew = "    const nameCol = rows.map(r => `<a href=\"/hiscores/player/${encodeURIComponent(r.username)}?profile=${profile}\" class=\"${playerSearch && r.username.toLowerCase() === playerSearch ? 'c yellow' : 'c'}\">${escapeHtml(r.username)}</a><br>`).join('\\n');";
const pagerAnchor = '                            </center>\n                        </td>\n                    </tr>\n                </table>\n\n                <br>\n\n                <!-- Search boxes -->';
const pagerCall = '                                ${hiscorePager(currentCategory, profile, pageStart, rankedTotal, playerSearch)}\n';
const rankOld = 'Rank: ${searchedPlayer.rank} |';
const rankNew = 'Rank: <a href="${hiscorePageHref(currentCategory, profile, Math.max(1, searchedPlayer.rank - 10), playerSearch)}" class="c yellow" title="Show on the table">${searchedPlayer.rank}</a> |';
const handler = 'export async function handleHiscoresPage(url: URL): Promise<Response | null> {';
const rankParse = "    const rankSearch = tryParseInt(url.searchParams.get('rank'), -1);";
const slicePattern = /^([ \t]*)rows = allResults\.slice\(startRank, startRank \+ 21\)/gm;

const count = (haystack, needle) => haystack.split(needle).length - 1;
const fail = why => {
    throw new Error(`Unexpected hiscore list page in ${name} (${why}); review upstream before rebuilding`);
};

let updated = text;
if (text.includes(marker)) {
    if (count(text, pagerCall) !== 1 || count(text, rankNew) !== 1 || count(text, nameColNew) !== 1 || count(text, 'pageStart = startRank;') !== 2) {
        fail('partially patched');
    }
} else {
    if (count(text, handler) !== 1) fail('list handler');
    if (count(text, rankParse) !== 1) fail('rank parameter');
    if ([...text.matchAll(slicePattern)].length !== 2) fail('21-row slices');
    if (count(text, nameColOld) !== 1) fail('name column');
    if (count(text, pagerAnchor) !== 1) fail('table end before the search boxes');
    if (count(text, rankOld) !== 1) fail('search result rank');
    updated = updated
        .replace(handler, () => helpers + handler)
        .replace(rankParse, () => `${rankParse}\n    let pageStart = 0;\n    let rankedTotal = 0;`)
        .replace(slicePattern, (line, indent) => `${indent}pageStart = startRank;\n${indent}rankedTotal = allResults.length;\n${line}`)
        .replace(nameColOld, () => nameColNew)
        .replace(pagerAnchor, () => pagerCall + pagerAnchor)
        .replace(rankOld, () => rankNew);
    fs.writeFileSync(filename, updated);
}
console.log('Hiscore list pager verified: Top/Prev/Next by 21 ranks, searched name highlighted and linked to its page');
