# The Postbox Game: free marketing plan (iOS + Android launch)

_Written 12 October 2026. Horizon: the 175th anniversary of Britain's first pillar boxes on 23 November 2027._

**Constraints this plan is built around**

- **£0 spend.** Free channels and free tools only.
- **1–2 hours a week** of the owner's time.
- **Anonymous.** The public voice is "The Postbox Game team". The guide character is the mascot but is never named in public copy.
- **UK-only product.**

Engineering work that supports the plan is listed in §14 and in the "Growth" notes in `CLAUDE.md`. The deferred product roadmap is in [`docs/plans/ROADMAP.md`](plans/ROADMAP.md).

---

## 1. Executive summary

The Postbox Game is live on both stores. Android (phone and Wear OS) is on Google Play, and the iPhone app was approved for the [App Store](https://apps.apple.com/gb/app/the-postbox-game/id6819213888) on 3 November 2026. The product already keeps players coming back: daily claims, streaks with a reminder push, friend pushes, county leaderboards, an Android widget, and a Wear tile and complications. What it lacked was any way for players to bring in other players. The only invite was a text message containing a 28-character account ID that the friend had to paste in by hand. There was nothing worth sharing, no link into the app, no rating prompt and no measurement of any of it.

With one or two hours a week and no budget, the plan rests on three bets:

1. **Every player is a recruiter.** Invite links open the app and add the friend in both directions. Every peak moment produces a share card that carries a tracked store link (`src=postbox_share`): a rare find, a streak milestone, a finished route. A rating prompt after good moments raises store ranking. These are built once and keep working without the owner.
2. **A niche-community launch burst, led by [r/Postboxes](https://www.reddit.com/r/Postboxes/).** The people who already care about postbox cyphers are the people most likely to evangelise a game about them. Start with r/Postboxes and the Letter Box Study Group, then add one community a week, with every link tracked. Keep the channels that produce installs and drop the ones that don't. **Update, 3 November 2026:** moderators removed both the r/Postboxes and the r/CasualUK launch posts, and r/CasualUK banned the account permanently. Reddit is now ask-first only (§4.2), and the burst leans on channels where permission is asked anyway: the LBSG, the OSM UK forum and the January press push.
3. **Seasonal, data-led content and store optimisation, about an hour a week.** The postbox dataset is a story generator. Only 143 Edward VIII boxes are mapped, and fewer Charles III boxes are mapped than that. Pair that data with dated hooks: the pillar box anniversary each 23 November, Christmas posting, January walking resolutions, and the 175th anniversary in November 2027 as the year's main PR moment.

**First 90 days:** ship the invite loop before iOS approval. Launch on r/Postboxes the day the iPhone app goes live, run one tracked community post a week, run a "Victorian Christmas" Remote Config event in December, and make a press push in the first week of January.

**12-month target:** weekly active claimers (the north star, §13) growing every month, with invites accepted per active player above zero and climbing. That number shows the product is recruiting for itself.

---

## 2. Strategic frame

### Positioning

- **Store hook (keep it):** "Turn every walk into a treasure hunt."
- **Community shorthand:** "geocaching for postboxes". People get it in four words.
- **Why it's different:** the rarity of real objects with real history. A Victorian box is worth more because it is rarer and older, not because a designer said so.

### Who it's for, in priority order

| # | Segment | Why they fit | Where they are |
|---|---|---|---|
| 1 | **Daily walkers**: dog walkers, step-counters, commuters | The once-a-day claim and streak match a walk they already take | Walking and dog groups, local Facebook groups, January resolution content |
| 2 | **Heritage and postbox enthusiasts** | They already know the cyphers, will top the leaderboards, and will talk about it | r/Postboxes, the Letter Box Study Group (LBSG), local history groups, pillar-box Instagram |
| 3 | **Friend and family groups** | Daily, weekly and monthly leaderboards, plus a friends filter | Reached through segments 1 and 2 by the invite loop |
| 4 | **OpenStreetMap mappers and geocachers** | Collectors who also fix data through the in-app reporting | OSM UK community forum, weeklyOSM, r/geocaching |

### Market check

The problem is small ("walks are a bit dull") but it comes up every day. That makes this a **habit product**: retention and word of mouth matter more than raw reach, which is why the referral loop is bet #1. The game covers the UK only, so the ceiling is real. Growth is about depth (players who claim daily and bring friends), not breadth.

### Voice rules (non-negotiable)

- Dry, warm, very British. Never hard-sell.
- The guide (internally Postman James) is the mascot. He is **never named** in anything a player or the public reads: store copy, posts, press releases, social bios.
- **No em-dashes in any line the guide speaks.** Use an ellipsis instead.
- When copy has the player addressing the guide, call him **"postie"** (for example, "Where now, postie?").
- Public copy speaks as **"The Postbox Game team"**.
- Postbox data comes from OpenStreetMap. Any published statistic carries "Postbox data © OpenStreetMap contributors, ODbL".

### The anonymity tradeoff

Journalists and Reddit both respond better to a named person. Staying anonymous costs some press pick-up and some Reddit warmth. Ways to soften it:

- Quote "The Postbox Game team" in press releases. That's normal for small studios.
- Be openly first-person on Reddit ("I made this") without a real name. Being honest that you made it matters more than giving a name.
- Let the data carry the story: county rarity tables and rare-box counts are newsworthy without a face.
- Use one free **brand Gmail** for all sign-ups, press and outreach. `web/support.html` currently shows a personal address; see Open decisions (§15).

### Data assets

Figures come from the repo's OpenStreetMap export, October 2026. Postbox data © OpenStreetMap contributors.

| Fact | Number |
|---|---|
| UK postboxes mapped in OpenStreetMap | **90,266** |
| Elizabeth II (EIIR) | 36,530 |
| Victoria (VR) | 3,618 |
| Edward VII (EVIIR) | 2,667 |
| Edward VIII (EVIIIR), the king who abdicated within a year | **143** |
| Charles III (CIIIR), the newest boxes | **81** |
| Mapped boxes with no cypher recorded | ~28,500 (about 30%) |
| LBSG estimate of all UK postboxes | ~115,500 |
| So roughly unmapped | **~25,000** |

Story angles that fall straight out of these numbers:
- "The new King's postboxes are rarer than the abdication king's."
- "A third of Britain's mapped postboxes have no recorded cypher. Players can fix that."
- "About 25,000 postboxes aren't on the map at all."

---

## 3. Current state

### Already built (acknowledge it, build on it)

- **Core loop:** fuzzy-compass discovery, a 30 m claim radius with a cypher quiz, once-a-day claims, rarity-weighted points.
- **Retention:**
  - daily streak with the "Don't lose your streak!" reminder push (17:00–21:00 London)
  - friend pushes ("First find of the day", "Overtaken!", "New friend!")
  - daily, weekly, monthly and lifetime leaderboards, a friends filter and county leaders
  - Android home-screen widget
  - Wear OS app with a tile, two complications and guest-mode scanning
- **Route Mode:** walk to a destination and collect boxes on the way.
- **Offline play:** claims are banked without signal and settled later.
- **Reporting:** missing boxes and wrong cyphers, with photos. Accepted fixes re-score claims and produce OpenStreetMap changesets. This gives the OSM community a real reason to care.
- **Store presence:**
  - Play listing with phone and Wear screenshots and a feature graphic
  - App Store listing copy and the 6.9" screenshot set (`fastlane/metadata/ios/`)
  - support, privacy and data-safety pages on `the-postbox-game.web.app`
- **Live-ops levers:** Remote Config already drives `points_by_monarch` on the server (`functions/src/_config.ts`), so points events need no app release.

### Gaps (these drove the in-app work in §7; owner steps are in §14)

| Gap | Fix | Status |
|---|---|---|
| Invite was a raw 28-character account ID pasted by hand | 8-character invite codes and links that add the friend both ways | Built (Phase 0/1) |
| No link could open the app | App Links, Universal Links and a `postboxgame://` scheme | Built (Phase 1), needs the console steps in §14 |
| Nothing worth sharing | Share cards for claims, streaks, routes and profiles, each carrying the tracked `/get?src=postbox_share` link (the sharer's invite link until November 2026) | Built (Phase 2) |
| No rating prompt | In-app review after good moments, at most once every 90 days | Built (Phase 2) |
| No growth analytics | `share`, `invite_link_opened`, `invite_accepted`, `tutorial_complete`, `first_claim`, `sign_up` (now including Google and Apple), `review_prompt_requested` | Built |
| Notification permission asked straight after login (iOS gives one shot) | Ask after the first claim, with a short pre-prompt from the guide | Built (Phase 1) |
| No landing page (the domain root is the web app) | `/get` landing page with store badges and OG tags; badges on the support page | Built (Phase 0) |
| Store copy leaked the guide's internal name | Fixed in the repo, plus a test guard; ships with the next iOS version | Done |
| Weekly recap, Postbox of the Day, friend challenges, badges | Not built; recommended order in §6 | Deferred |

---

## 4. Acquisition: strangers to installs

### The tracking rule

Every link the owner posts carries a channel tag. Use the landing page so one link works for both phones:

`https://the-postbox-game.web.app/get?src=<channel>`

The `/get` page forwards `src` into the store links: App Store `ct=<channel>` (with the provider token `pt`) and Play `referrer=utm_source%3D<channel>`. App Store Connect's app analytics (campaign sources) and Play Console's acquisition reports (UTM-tagged traffic) then show installs per channel, free.

**Kill rule:** drop a channel after **two attempts with fewer than 5 tracked installs** between them. Put the time into the next one on the list.

**A removal or a ban ends a channel at once.** Never repost removed content, and never use another account to get round a ban: that breaks Reddit's sitewide rules and risks the whole account, which would close every Reddit channel at once.

### 4.1 Store featuring and ASO

About 2 hours once, then 15 minutes a month.

| Move | Mechanism | Effort | Keep if |
|---|---|---|---|
| **Apple Featuring Nomination** ("new app launch") | App Store Connect → the app → Featuring → Nominations | 20 minutes on approval day | Free lottery ticket; always do it |
| Nominate again for big updates (share cards, the 175th event) | Same form, "app enhancements" type | 15 minutes each | Same |
| **Rotate iOS promotional text** with the seasons | Changes without a new version (drafts in §4.6) | 5 minutes per season | Conversion rate (App Store Connect) holds or rises |
| **Play store listing experiments** | Free A/B tests of icon, short description and screenshots in Play Console | 30 minutes setup, check monthly | Run one experiment at a time until it has a winner |
| Keyword review | After 30 days of App Store Connect search-term data, swap the weakest keywords | 30 minutes in mid-November | Impressions from search rise |
| **Wear OS angle** | Wear games are a thin category; lead with the watch screenshots in Wear-focused posts | Built into posts | Wear installs (Play Console, wear track) |
| Reply to every store review | Replies are public. Polite, funny replies are free ad copy | 15 minutes a week (routine) | Always |

### 4.2 Launch communities: r/Postboxes first, then one a week

**Ask the mods first, every time.** Reading the rules was not enough. On 3 November 2026 both launch posts were removed: r/Postboxes gave no reason, and r/CasualUK cited its Rule 5 (advertising is not permitted; surveys, AMAs and PSAs need prior approval) and banned the account permanently. Before posting in any subreddit, take part there for a while, then send the mods a short modmail (draft in §4.6a) and post only after a written yes. Removals close together make a new account look like spam to Reddit itself, so leave a clear gap after any removal. Always say you're the maker.

**[r/Postboxes](https://www.reddit.com/r/Postboxes/) is the home community, not a one-off post.**
- **The launch post (draft in §4.6a) was removed on 3 November 2026.** Look for the removal reason (a removal comment on the post, or the Reddit inbox). Comment helpfully, with no links, for a week or two, then send the modmail in §4.6a. Repost only if the mods say yes.
- **Then 15 minutes a week:** reply to threads and help with cypher questions. Until the mods approve, no links, share cards or app mentions. After a yes, and only as far as the mods allow: one rare find a week (a share card, or a player's photo with permission) and a monthly "rarest boxes claimed this month" titbit from the data.
- **Ask for help with cypher identification.** About 30% of mapped boxes have no cypher recorded, and the in-app "report wrong or missing cypher" flow turns the sub's expertise into OpenStreetMap fixes. That makes the sub a partner, not an audience.

**The staggered list** (one a week, about 45 minutes each including replies, best fit first):

| Week | Channel | Angle | `src` tag |
|---|---|---|---|
| 1 | r/Postboxes | Home community, launch post | `reddit_postboxes` |
| 2 | ~~r/CasualUK~~ | **Banned 3 Nov 2026** under Rule 5 (no advertising). Closed for good | ~~`reddit_casualuk`~~ |
| 3 | LBSG, by email | Their members' knowledge puts them top of the leaderboards; ask for a newsletter mention (draft in §4.6c). **Scheduled for 9 Nov 2026** to enquiries0501@lbsg.org | `lbsg` |
| 4 | OSM UK community forum plus a weeklyOSM news tip | A game that turns walkers into OSM data fixers (reports produce `.osc` changesets) | `osm_forum`, `weeklyosm` |
| 5 | r/WearOS | A real standalone Wear game with a tile and complications | `reddit_wearos` |
| 6 | r/geocaching | "Geocaching for postboxes": rarity, collection, a daily claim | `reddit_geocaching` |
| 7 | r/AndroidGaming and r/iosgaming | Free, no ads, UK-only walking game | `reddit_androidgaming`, `reddit_iosgaming` |
| 8 | Local history and walking Facebook groups (2–3 groups) | **Ask admins first.** Local rarity angle from the county table (§4.6d) | `facebook_groups` |
| 9 | r/FlutterDev | "Built with Flutter": Wear, offline claims, fuzzy compass | `reddit_flutterdev` |

Every subreddit row needs a written yes from that sub's mods before anything is posted, so send the modmail a week or two before the row's slot. The LBSG, OSM forum and Facebook rows already ask first.

### 4.3 Data-led press: two bursts a year

About 3 hours each: one hour to refresh the numbers, two to send emails.

- **Burst 1: first week of January 2027.** "Britain's rarest postboxes", plus the new-year walking angle. Draft in §4.6d.
- **Burst 2: September–November 2027.** The 175th anniversary of the first British Isles pillar boxes (St Helier, Jersey, 23 November 1852).
- **Targets:**
  - regional news desks and BBC local radio, matched to the county table (local papers love "your county's rarest box")
  - heritage and walking magazines' news pages
  - the LBSG and the Postal Museum's social accounts, as a courtesy heads-up rather than a pitch (both were first emailed on 9 November 2026: §4.6c, §4.6g)
- **Mechanism:** one release, with a one-line localised opening per county sent to that county's outlets. Use the brand Gmail. Attach the share-card image and a screenshot.
- **Keep if:** at least one pickup, or tracked `press` installs, per burst. If burst 1 gets nothing, cut burst 2 to the anniversary-only version.

### 4.4 Owned social: one channel, batched monthly

About 1 hour a month.

- **Instagram,** cross-posted to a **Facebook page** through **Meta Business Suite**'s free scheduler. One upload, two places.
- **Four posts a month, scheduled in one sitting.** Rotate four kinds:
  1. **Cypher of the week:** one cypher, one fact, its points value.
  2. **Rare-box facts** from the data ("Glasgow has more mapped Edward VIII boxes than anywhere else").
  3. **Player share cards,** reposted only with the player's permission.
  4. **Seasonal:** the anniversary, Christmas posting, January walks.
- **Tools:** free Canva templates in the brand colours (postal red `#C8102E`, gold `#FFB400`, navy `#0A1931`).
- **Keep if:** tracked `instagram` and `facebook_page` installs are above the kill rule after 2 months. If not, stop posting but keep the accounts (they reserve the name and host repost-able cards).

### 4.5 Web

- `https://the-postbox-game.web.app/get` is **the one canonical marketing link**: pitch, screenshots, both store badges and Open Graph tags, so it previews well in WhatsApp, Reddit and iMessage.
- The support page now carries store badges, and the web app shell has Open Graph tags.
- **Later:** a "Get the app" nudge for people who play in the browser (not built yet; see §12).

### 4.6 Ready-to-use assets

#### a) r/Postboxes launch post

> **Title:** I made a free game about spotting postbox cyphers. Would love this sub's eyes on it
>
> I'm the (very amateur) maker of **The Postbox Game**, a free UK game for iPhone, Android and Wear OS. No ads, no in-app purchases.
>
> The idea is simple. When you walk past a postbox you can claim it once a day by naming its royal cypher. Rarer cyphers score more: EIIR is 2 points, Victorian boxes 7, Edward VII and Charles III 9, and Edward VIII 12. A deliberately vague compass hints at which direction unclaimed boxes are in, so you still have to go and look.
>
> The postbox data comes from OpenStreetMap: about 90,000 boxes. That's where I could use this sub's help. About a third of them have no cypher recorded at all, and some are wrong. There's a "report wrong or missing cypher" button in the app (photos welcome), and accepted fixes go back to OpenStreetMap so the map improves for everyone.
>
> A few numbers you might enjoy: there are only 143 Edward VIII boxes mapped, and only 81 Charles III ones, so the new King's boxes are currently rarer than the abdication king's.
>
> Happy to take any criticism, especially cypher-related pedantry. That's exactly what I need.
>
> https://the-postbox-game.web.app/get?src=reddit_postboxes

_(Removed by the r/Postboxes mods on 3 November 2026. Don't repost it. Send the modmail below, and use this text only if the mods approve.)_

**Modmail to the mods first.** Written for r/Postboxes after the removal; for a sub you haven't posted in, drop the apology and adapt the last paragraph.

> **Subject:** My postbox game post
>
> Hi mods, sorry about the post you removed. I'm the maker of The Postbox Game, a free game where you claim real postboxes by naming their royal cypher (no ads, no purchases). I should have asked before posting.
>
> Would you be happy for it to appear here in any form? A post you approve first, a mention in a megathread, or not at all are all fine.
>
> I hoped to share it with this sub in particular because about a third of the 90,000 postboxes on OpenStreetMap have no cypher recorded. The app has a button for reporting wrong or missing cyphers, with photos, and accepted fixes go back to OpenStreetMap. Nobody knows cyphers better than this sub, so I'd value your help even if the answer on promotion is no.
>
> Thanks for running the place.

#### b) Generic community post template

> **Title:** [One honest sentence about what it is, tuned to the community]
>
> I made a free UK walking game where you claim real postboxes by naming their royal cypher. Rarer boxes score more (a Victorian one is worth 7 common ones... nearly). [One line tuned to this community: Wear tile / OSM fixes / geocaching-style collecting / built with Flutter.] No ads, no purchases. Feedback very welcome.
>
> https://the-postbox-game.web.app/get?src=[channel]

#### c) LBSG outreach email

**Scheduled for 9 November 2026** to the Group's general address, enquiries0501@lbsg.org (lbsg.org names no Secretary; the Chair is Andrew R Young). The version sent is a personal one, signed by the owner by name. It opens with the game's origin (a friend's long-running informal cypher-spotting game) and keeps this draft's OpenStreetMap and newsletter asks. Members get a quarterly Newsletter; 2026 is the Group's Golden Jubilee (founded 1976, 200th issue in March). The draft below is kept for reference.

> **Subject:** A free postbox game that sends cypher fixes back to OpenStreetMap
>
> Dear Secretary,
>
> We're the small team behind **The Postbox Game**, a free UK game for iPhone and Android in which players find real postboxes on their walks and claim them by identifying the royal cypher. Rarer cyphers score more, so a Victorian or Edward VIII box is a real prize.
>
> We know the Group is the authority on Britain's letter boxes, and we're not trying to replace anything you do. Our postbox data comes from OpenStreetMap, and about a third of mapped boxes have no cypher recorded. Players can report a missing or wrong cypher, with photos, and accepted corrections are turned into OpenStreetMap edits.
>
> Your members would, frankly, top our leaderboards within a week. If you thought a mention in a newsletter or on your website might interest them, we'd be very grateful, and we'd welcome any corrections or advice on how we describe the cyphers.
>
> The app is free, with no adverts or purchases: https://the-postbox-game.web.app/get?src=lbsg
>
> With best wishes,
> The Postbox Game team

#### d) Press release: "Britain's rarest postboxes"

> **FOR IMMEDIATE RELEASE**
>
> **The new King's postboxes are rarer than the abdication king's, and you might be walking past one**
>
> Britain has more than 90,000 postboxes on the open map. Fewer than 150 carry the cypher of Edward VIII, who reigned for less than a year. Rarer still are the boxes of King Charles III: just 81 are mapped so far.
>
> The figures come from **The Postbox Game**, a free app for iPhone and Android that turns walks into a hunt for royal cyphers. Players claim real postboxes once a day by naming the monarch whose cypher is on the front, and rarer boxes score more points.
>
> | Cypher | Monarch | Mapped boxes | Points in the game |
> |---|---|---|---|
> | EIIR | Elizabeth II | 36,530 | 2 |
> | GR / GVR / GVIR | George V and George VI | about 14,500 | 4 |
> | Scottish Crown | (Scotland, post-1952) | 3,966 | 4 |
> | VR | Victoria | 3,618 | 7 |
> | EVIIR | Edward VII | 2,667 | 9 |
> | CIIIR | Charles III | 81 | 9 |
> | EVIIIR | Edward VIII | 143 | 12 |
>
> **Where the rare boxes are.** The places with the most mapped Victorian, Edward VII and Edward VIII boxes are: [paste the top 5 counties from the table below, with counts]. Glasgow has more mapped Edward VIII boxes than anywhere else in the UK.
>
> **And thousands are missing from the map.** The Letter Box Study Group estimates there are about 115,500 postboxes in the UK, which leaves roughly 25,000 unmapped. A third of the mapped boxes have no recorded cypher. Players can report missing boxes and wrong cyphers in the app, and accepted fixes are sent back to OpenStreetMap.
>
> "Most people walk past a piece of Victorian history every day without noticing," said The Postbox Game team. "We wanted to give them a reason to look up. The surprise for us was how rare the newest boxes are."
>
> **Notes to editors**
> - The Postbox Game is free on the App Store and Google Play, with no adverts or in-app purchases. Link: https://the-postbox-game.web.app/get?src=press
> - Postbox data © OpenStreetMap contributors, available under the Open Database Licence. Counts are of boxes mapped in OpenStreetMap as of [date] and may not match Royal Mail's own records.
> - The UK total estimate is from the Letter Box Study Group.
> - Contact: [brand Gmail]. Images: share card, app screenshots (attached).

**County table** (generated offline from `postboxes.json` with the importer's own county lookup, `functions/util/county_lookup.js`; ONS counties and unitary authorities, so London boroughs and cities appear separately). Rare = VR + EVIIR + EVIIIR.

| County / unitary authority | Mapped boxes | VR | EVIIR | EVIIIR | CIIIR | Rare total |
|---|---|---|---|---|---|---|
| Devon | 2,302 | 202 | 90 | 1 | 4 | **293** |
| Kent | 2,957 | 170 | 69 | 3 | 6 | **242** |
| Cornwall | 1,692 | 129 | 36 | 0 | 2 | **165** |
| Surrey | 2,271 | 62 | 90 | 12 | 1 | **164** |
| Gloucestershire | 1,323 | 91 | 54 | 0 | 2 | **145** |
| North Yorkshire | 1,642 | 106 | 34 | 1 | 3 | **141** |
| Norfolk | 1,947 | 96 | 40 | 0 | 1 | **136** |
| Hampshire | 2,615 | 64 | 51 | 1 | 8 | **116** |
| East Sussex | 1,361 | 76 | 36 | 2 | 1 | **114** |
| Somerset | 1,184 | 74 | 37 | 2 | 2 | **113** |

Most mapped Edward VIII boxes: Glasgow City 15, Surrey 12, Bristol 4, Hertfordshire 4, Birmingham 4.
Most mapped Charles III boxes: Hampshire 8, Kent 6, Devon 4, West Sussex 4, North Yorkshire 3.

**Refreshing the numbers before each burst** (read-only, never touches Firestore): run `osm_import.sh` with `--dry-run`, or just re-download, to refresh `postboxes.json`. Then load `functions/util/county_lookup.js` in a short Node script, call `countyForPoint(lat, lon)` for each element, and count `tags.royal_cypher` per county. That's about 20 lines, the same method as above.

#### e) iOS promotional text (each 170 characters maximum; counted)

| Season | Text | Characters |
|---|---|---|
| Launch | Now on iPhone. Turn every walk into a postbox hunt: name the royal cypher, claim the box, and race your friends to the rare Victorian ones. | 139 |
| Christmas | Posting your Christmas cards? Claim the postbox while you're there. Every box counts, and the rare Victorian ones count for a lot more. | 135 |
| January | New year, more walks. Every postbox you pass is points on the board. Start a daily streak and see where a week of walking gets you. | 131 |
| 175th | 175 years since Britain's first pillar boxes went up in Jersey. Mark it by finding one: some on your street have stood for over a century. | 138 |

#### f) Campaign links

| Channel | `src` / `ct` / `utm_source` | Link |
|---|---|---|
| r/Postboxes | `reddit_postboxes` | https://the-postbox-game.web.app/get?src=reddit_postboxes |
| ~~r/CasualUK~~ (banned) | ~~`reddit_casualuk`~~ | Don't use |
| LBSG | `lbsg` | https://the-postbox-game.web.app/get?src=lbsg |
| OSM UK forum | `osm_forum` | https://the-postbox-game.web.app/get?src=osm_forum |
| weeklyOSM | `weeklyosm` | https://the-postbox-game.web.app/get?src=weeklyosm |
| r/WearOS | `reddit_wearos` | https://the-postbox-game.web.app/get?src=reddit_wearos |
| r/geocaching | `reddit_geocaching` | https://the-postbox-game.web.app/get?src=reddit_geocaching |
| r/AndroidGaming | `reddit_androidgaming` | https://the-postbox-game.web.app/get?src=reddit_androidgaming |
| r/iosgaming | `reddit_iosgaming` | https://the-postbox-game.web.app/get?src=reddit_iosgaming |
| Facebook groups | `facebook_groups` | https://the-postbox-game.web.app/get?src=facebook_groups |
| r/FlutterDev | `reddit_flutterdev` | https://the-postbox-game.web.app/get?src=reddit_flutterdev |
| Instagram bio | `instagram` | https://the-postbox-game.web.app/get?src=instagram |
| Facebook page | `facebook_page` | https://the-postbox-game.web.app/get?src=facebook_page |
| Press releases | `press` | https://the-postbox-game.web.app/get?src=press |
| The Postal Museum | `postal_museum` | https://the-postbox-game.web.app/get?src=postal_museum |
| In-app invites | `invite` | Generated per player: `https://the-postbox-game.web.app/invite/<CODE>` |
| In-app share cards | `postbox_share` | https://the-postbox-game.web.app/get?src=postbox_share (built into the app) |

#### g) The Postal Museum introduction email

A courtesy introduction, not a request for promotion. The real ask is the 175th anniversary paragraph, followed up in spring 2027 (§10). It opens with the same origin story as the LBSG email, so the two tell the same story if they ever compare notes. **Scheduled for 9 November 2026,** the same morning as the LBSG email.

> **Subject:** A free postbox game, and the 175th anniversary of the pillar box
>
> Dear Postal Museum team,
>
> For many years a close friend of mine has played an informal game spotting the cyphers on postboxes. Inspired by his interest, I developed The Postbox Game, a free app for iPhone and Android in which players find real postboxes on their walks and claim them by identifying the royal cypher. Rarer cyphers score more, so a Victorian or Edward VIII box is a real prize, and players end up learning to read the history in the street around them.
>
> Our postbox data comes from OpenStreetMap, and about a third of mapped boxes have no cypher recorded. Players can report a missing or wrong cypher, with photos, and accepted corrections go back to OpenStreetMap, so the map improves for everyone.
>
> I wanted to let you know about it, since the collection and research behind your work is the story the game is built on. I'd very much welcome any corrections to how we describe the cyphers and their history.
>
> Looking further ahead, 23 November 2027 marks 175 years since the first pillar boxes in the British Isles, in St Helier. We'd love to mark it in the game, and if the Museum is planning anything for the anniversary, I'd be glad to talk about whether the game could play a small part.
>
> The app is free, with no adverts or purchases: https://the-postbox-game.web.app/get?src=postal_museum
>
> With best wishes,
> [Name]

**Royal Mail is deliberately not contacted.** A commercial company's press office is very unlikely to promote a third-party app, and the game needs nothing from it (the data comes from OpenStreetMap). An approach would put the game in front of its brand and legal teams for no gain. Revisit only after real traction or press pickup, and then via its heritage or stamps side around the 175th, not corporate press.

---

## 5. Activation: installs to first claim

The moment that matters is the **first claim**. Until then the player has only watched an intro and signed in.

- **The funnel, now measurable in Firebase Analytics:** `first_open` → `tutorial_complete` → `sign_up` → first scan (`scan_started`) → `first_claim`. Check it weekly in the dashboard (§11). The biggest drop is the step to fix next.
- **Notification permission timing (built).** The app used to ask for push permission straight after login, before any value. iOS only asks once, and streak reminders and friend pushes depend on that permission. The ask now comes **after the first successful claim**, behind a one-line pre-prompt from the guide. Expect a higher opt-in rate on iOS, and watch the pre-prompt accept rate in analytics.
- **Store-page conversion** (App Store Connect product page views → first-time downloads; Play store listing visitors → acquirers) is improved by the listing experiments and seasonal promotional text in §4.1.
- **Later candidates** (§12), once the funnel shows where people stall:
  - a first-scan nudge from the guide after sign-in
  - the interactive tutorial spec (`docs/map-specs/F2-interactive-tutorial.md`)
  - a "Get the app" nudge for web players

---

## 6. Retention: keep them claiming

**Already working:** streak reminder, friend pushes, the Android widget and Wear tile and complications, county leaderboards. Don't touch what works. Watch D7 retention (§13).

### Remote Config events (no release needed)

The server reads `points_by_monarch` from Remote Config, so a time-limited points event is a console change:

1. In Remote Config, edit `points_by_monarch` (for example, double the VR value for "Victorian Christmas"). Publish at the start of the window.
2. Announce it: the iOS promotional text, an App Store **In-App Event** (it goes through App Review, so submit well ahead), one social post and the r/Postboxes weekly slot.
3. At the end of the window, set the value back. Claims made during the window keep their points.

**Caveats:**
- **Hold cypher-correction reviews for affected boxes until the event ends.** An accepted correction re-scores every claim on that box at whatever values are live at the time.
- The client may show standard points until its Remote Config refreshes. The server is authoritative for scoring.
- Keep events to a weekend or a week. Long multipliers distort the lifetime leaderboard.

**Planned events:** "Victorian Christmas" (a December weekend), "Coronation week" around 6 May (Charles III boxes are worth more), and "175 week" around 23 November 2027.

### Recommended next product steps (ROADMAP v1.7, not built yet)

1. **Weekly recap with a share card.** It is both retention and referral, and it reuses the share-card work.
2. **Postbox of the Day:** a daily reason to open the app and a push hook.
3. **Friend challenges:** they need a dense friend graph, which the invite loop is now building.
4. **Badges:** later, in v1.8. They're also where a cosmetic referral badge would live.

---

## 7. Referral: players bring players

### How the loop works (built)

1. **Every player gets an invite code:** 8 characters, unambiguous letters and digits (no I, L, O or U). It's short enough to read out or type.
2. **The invite link** is `https://the-postbox-game.web.app/invite/<CODE>`. The Friends tab's "Invite friends to play" now shares just this link.
3. **If the friend has the app,** the link opens it directly (App Links on Android, Universal Links on iPhone). The app shows "Add [name] as a friend?", and accepting adds both players to each other's friends list. The inviter gets the existing "New friend!" push, which is their reward signal.
4. **If they don't have the app,** the invite page shows the code, store badges and an "Open in the app" button. On Android the app can pick the code up after install (an optional install-referrer step). On iPhone they tap the link again after installing, or type the code into the Friends tab.
5. **A link opened while signed out** survives the intro and sign-up, and the friend prompt appears once they're in.
6. **"Added you"** on the Friends tab lists people who added you and offers a one-tap add back. Profiles opened from the leaderboard and county map have an "Add friend" button.

**Why codes, not account IDs:** account IDs are visible on public leaderboard rows. If a raw ID could force a mutual add, a stranger could put themselves on anyone's list and trigger their daily pushes. Codes are only known to people the player shared them with.

### Share cards (built)

- Share moments: claim success, streak milestones (7, 30 and 100 days), route completion and your own profile.
- Card content: the cypher and its era colour, points, streak, the guide's artwork and the invite link.
- **No map, location, county or name on the card**, so nobody leaks their home postbox.
- The guide nudges a share on rare claims (7 points or more).
- Each share is logged as `share` with its content type.

### Rating prompt (built)

- Asked only right after a good moment: a rare claim or a 3- or 7-day streak.
- Never on the account's first day, and at most once every 90 days.
- The stores also rate-limit the prompt themselves.
- Ratings feed store ranking, and ranking is free acquisition.

### No points for referrals, deliberately

Points for referrals would reward fake accounts, and the anti-cheat and leaderboards exist to stop exactly that. Referral attribution is recorded server-side, and only for accounts under a week old. If a reward is ever wanted, make it a **cosmetic badge** when badges ship (v1.8). It's in Open decisions.

**Metric:** invites accepted per weekly active player, the k-factor (§13).

---

## 8. Revenue and costs

**Revenue is out of scope.** The game is free, with no ads and no in-app purchases, and this plan doesn't change that.

**Growth still costs money in Firebase.** More players mean more Firestore reads, more Cloud Functions calls and more pushes.
- Before each press burst, re-read [`docs/firebase-costs.md`](firebase-costs.md).
- Set a free **Cloud Billing budget alert** (owner checklist, §14) so a spike from a lucky pickup sends an email, not a surprise invoice.

---

## 9. First 90 days (12 October 2026 to 10 January 2027)

Owner time is in brackets. "Eng" is engineering work done in the repo, not owner hours. AARRR tags: Acq, Act, Ret, Ref.

| Week of | What | AARRR | Owner time |
|---|---|---|---|
| **12 Oct** | **Before iOS approval:** Eng ships Phase 0 (hosting pages, `.well-known` files, invite functions, store-copy fix) and Phase 1 (invite loop, add back, notification timing, growth analytics). Owner: brand Gmail; Instagram and Facebook page; Meta Business Suite; budget alert | Ref, Act | 2 h |
| **19 Oct** | Owner deploys hosting, functions and rules (§14); Play signing SHA-256 into `assetlinks.json`; Android release with Phase 1. Start a Play listing experiment (short description). Join r/Postboxes and read the rules | Ref, Acq | 1.5 h |
| **26 Oct** | **iOS approval (expected; it came on 3 Nov):** featuring nomination; launch promotional text; **r/Postboxes launch post**. If review drags past 2 Nov, post anyway with "iPhone coming very soon" | Acq | 1.5 h |
| **2 Nov** | **iOS live 3 Nov:** featuring nomination (done); Apple campaign provider token (done, §14); launch promotional text; r/Postboxes launch post and r/CasualUK post. **Outcome:** the mods removed both posts and r/CasualUK banned the account (§4.2), so Reddit is paused. (Associated Domains and the Phase 1 iOS build were already done: the approved build 454 carries both.) | Acq, Ref | 2 h |
| **9 Nov** | LBSG email and Postal Museum email (both scheduled for the morning of 9 Nov; §4.6c, §4.6g). Schedule the 23 November post, which needs the Instagram and Facebook accounts (§14 item 5). Reply to either email within a day | Acq | 1 h |
| **16 Nov** | OSM UK forum post plus weeklyOSM tip (check the forum's rules on announcements first). Keyword review (30 days of data). Modmails (§4.6a): r/Postboxes, plus r/WearOS and r/geocaching asking about their slots | Acq | 2 h |
| **23 Nov** | **Pillar box anniversary** (St Helier, 1852) post: warm-up for the 175th. r/WearOS post, only with the mods' written yes. If the annual recap (PR #197) is shipping, its app release should be live by now (§14 item 9) | Acq, Ret | 1 h |
| **30 Nov** | Prepare "Victorian Christmas": submit the In-App Event, schedule posts, Christmas promotional text. r/geocaching post, only with the mods' written yes | Ret, Acq | 1.5 h |
| **7 Dec** | Eng ships Phase 2 (share cards, rating prompt). Featuring nomination for the update | Ref | 1 h |
| **14 Dec** | **Victorian Christmas weekend:** flip Remote Config on Friday, off on Monday. Pick a weekend before Royal Mail's published last posting dates | Ret | 1 h |
| **21 Dec** | Light week: dashboard and review replies only | n/a | 0.5 h |
| **28 Dec** | January promotional text, Play experiment review, refresh press numbers, build the county pitch list | Acq | 1.5 h |
| **4 Jan** | **Press burst 1** ("rarest postboxes" plus new-year walking). r/AndroidGaming and r/iosgaming, if their mods said yes (ask in December) | Acq | 3 h (one-off over budget) |

Two weeks run over the 2-hour budget: the setup week (in effect) and the press week. Every other week fits.

**Day-90 review:** which channels passed the kill rule? What's the k-factor? Where does the activation funnel leak? Use the answers to set the Q1 plan.

---

## 10. Twelve-month calendar (to 23 November 2027)

| When | Hook | Moves |
|---|---|---|
| Oct–Nov 2026 | Two-store launch | §9 |
| 23 Nov 2026 | First pillar boxes, St Helier, Jersey, 1852 | Anniversary post; warm-up for the 175th |
| Dec 2026 | Christmas posting | Victorian Christmas event; Christmas promotional text |
| Jan 2027 | New Year walking resolutions, **the biggest acquisition window** | Press burst 1; walking and dog-walking communities; January promotional text; keyword refresh |
| Feb–Mar 2027 | Quiet season | Recommended product work: weekly recap with a share card (§6) |
| Mar–Apr 2027 | Easter walks, lighter evenings | Promotional text; family-walk angle in Facebook groups; **follow up with the Postal Museum about the 175th** (museums plan anniversaries months ahead; bring player numbers) |
| 6 May 2027 | Coronation anniversary | "Coronation week" Charles III points event; post about how rare CIIIR boxes are |
| Jun–Aug 2027 | Summer holidays, staycations | Holiday angle ("collect a county"); county leaderboard posts |
| Sep 2027 | Prepare for the 175th | Refresh the data; press list; build the "175 week" event; submit the In-App Event early |
| 9 Oct 2027 | World Post Day | Social post; r/Postboxes titbit |
| **23 Nov 2027** | **175th anniversary of Britain's first pillar boxes** | Press burst 2; "175 week" Remote Config event; In-App Event; featuring nomination; anniversary promotional text |

---

## 11. Weekly routine (about 75 minutes a week, plus 1 hour a month)

| Slot | What | Time |
|---|---|---|
| Dashboard | Installs by `src` channel (App Store Connect, Play Console); invites sent and accepted, shares and `first_claim` (Firebase Analytics); new ratings | 15 min |
| r/Postboxes | Reply to threads and help with cypher questions. No links or app mentions until the mods approve (§4.2); after that, one rare find or data titbit | 15 min |
| One queued move | The week's community post or outreach email (§9) | 30 min |
| Store reviews | Reply to every review on both stores | 15 min |
| **Monthly** | Batch-schedule four social posts in Meta Business Suite; check the Play listing experiment | 60 min |

If a week is squeezed, cut in this order: the queued move first, then social. Keep the dashboard and review replies.

---

## 12. Idea bank

| Idea | Status | Why |
|---|---|---|
| Invite links and codes, two-way friend add | **Now (built)** | Removes the biggest referral friction |
| Share cards at peak moments | **Now (built)** | Every share is an ad plus an invite |
| In-app rating prompt | **Now (built)** | Ratings feed ranking |
| r/Postboxes as home community | **Now**, ask-first (launch post removed 3 Nov 2026) | Highest fit, gives expert cypher help |
| Apple Featuring Nomination | **Now** | Free, 20 minutes |
| Play store listing experiments | **Now** | Free A/B testing |
| Seasonal promotional text | **Now** | 5 minutes, no release |
| Remote Config points events | **Now** | Live-ops without a release |
| App Store In-App Events | **Now** (per event) | Free discovery surface |
| Data-led press, 2 bursts | **Now** | The data is the story |
| Instagram and Facebook, monthly batch | **Now** | Minimal time, reserves the name |
| Android install referrer (code survives install) | Later | Optional Phase 3; small engineering job |
| Weekly recap share card | Later (v1.7) | Retention plus referral in one |
| Postbox of the Day | Later (v1.7) | Daily open reason, push hook |
| Friend challenges | Later (v1.7) | Needs the friend graph the invite loop builds |
| "Get the app" nudge for web players | Later | Small; measure web traffic first |
| First-scan nudge or interactive tutorial | Later | Do it if the funnel shows a stall at sign-up → first scan |
| Cosmetic referral badge | Later (v1.8) | Only once badges exist |
| Notification-tap routing | Later | Pushes currently open the app's default tab |
| Google Play Indie Games programmes | Later | Check eligibility and dates each year |
| Play promotional content (LiveOps) | Later | Check whether Play Console offers it to this app |
| Product Hunt, Hacker News | Skip (for now) | Global audiences; the game is UK-only |
| Paid ads, paid influencers, prize giveaways | Skip | Cost money |
| Custom domain | Skip | About £10 a year; not free |
| On-camera video or a named founder story | Skip | Owner is staying anonymous |
| Points for referrals | Skip | Rewards fake accounts |
| Cold-messaging creators | Skip | Too time-hungry at 1–2 hours a week; revisit if press works |

---

## 13. Measurement

**North star: weekly active claimers**, players with at least one claim in the week (Firebase Analytics: users with `claim_success`, weekly). It captures acquisition, activation and retention in one number.

| Indicator | Source | Healthy signal |
|---|---|---|
| Installs by channel | App Store Connect app analytics, campaign sources (`ct`); Play Console acquisition reports by `utm_source` | A channel passes the kill rule (5 or more installs from 2 attempts) |
| Store conversion | App Store Connect (product page views → downloads); Play Console (listing visitors → acquirers) | Stable or rising after each listing change |
| Sign-up rate | Firebase: `first_open` → `sign_up` (now logged for Google and Apple too) | Rising |
| Activation | Firebase: `tutorial_complete` → `first_claim` within 24 hours | The biggest drop is the next thing to fix |
| D7 retention | Firebase Analytics retention cohorts | Doesn't fall as volume grows |
| Invites sent | Firebase: `share` where content type is invite | Rises with weekly active players |
| Invites opened and accepted | Firebase: `invite_link_opened`, `invite_accepted` | Acceptance rate above 30% of opens |
| **k-factor** | `invite_accepted` ÷ weekly active claimers | Above 0 and rising; over 0.1 is good for a niche game |
| Shares per claim | `share` (claim, streak or route type) ÷ `claim_success` | Rising after Phase 2 |
| Rating prompts | `review_prompt_requested`, plus the stores' rating count and average | Average 4.5 or higher; count rising |
| Notification opt-in | Firebase: notification pre-prompt accept rate; iOS authorised share | Higher than before the timing change |

**Kill rule (repeated):** two attempts with fewer than 5 tracked installs means stop and move the time to the next channel. Check monthly.

---

## 14. Owner checklist (manual and console steps)

Do these in order. The engineering is already in the repo; these steps can't be automated.

1. ~~**Play Console → App integrity:** confirm the fingerprints in `web/.well-known/assetlinks.json`.~~ Done 13 Oct 2026: `F9:13:80:66:…` matches Play's Digital Asset Links JSON (the app-signing key), and `3C:9F:79:DC:…` is the upload key, kept for the off-Play `auto` build.
2. ~~**Apple Developer → Identifiers → `com.code418.postboxGame` → enable Associated Domains.** Regenerate the App Store profile **with the same name**, "Postbox Game App Store".~~ Done: build 454 (1.5.3, 16 Oct 2026) was signed with that profile carrying the `applinks:` entitlement, and it is the build Apple approved on 3 November, so invite links open the iPhone app. Apple's CDN serves the correct `apple-app-site-association`.
3. **Deploy** (when ready): `firebase deploy --only hosting,functions,firestore:rules`. Then check that `curl -sI https://the-postbox-game.web.app/.well-known/apple-app-site-association` returns `content-type: application/json`, not HTML. **Deploy hosting before any build with the link entitlement ships,** because Apple's CDN caches what it first sees.
4. **App Store Connect:**
   - get your campaign provider token (`pt`): App Store Connect → Apps → The Postbox Game → **Analytics** → Acquisition → **Campaigns** → **+**, generate a link with any campaign name, and copy the number after `pt=` in it. It identifies the developer account, so it's the same for every campaign, and it isn't secret (it appears in every public campaign link). Campaigns only appears once the app has some analytics data, so this can't be done before launch and may take a few days after it. Put the number in `APPLE_PROVIDER_TOKEN` in `web/invite.html` and `web/get.html`, then `firebase deploy --only hosting`. Until then, App Store links carry no `ct` and iOS installs can't be split by channel. **Done 3 Nov 2026:** `pt=129562838` is in both pages; it takes effect at the next hosting deploy
   - ~~submit the **Featuring Nomination** ("new app launch") on approval day~~ Done 3 Nov 2026. Next: an "app enhancements" nomination for the Phase 2 update (§9, week of 7 Dec)
   - at the next version, paste the fixed description (`fastlane/metadata/ios/en-GB/description.txt`, now "MEET YOUR GUIDE")
5. **Accounts:**
   - create one free **brand Gmail** for social sign-ups, press and outreach
   - create the **Instagram** account and **Facebook page**, and link them in **Meta Business Suite**
   - put `https://the-postbox-game.web.app/get?src=instagram` in the Instagram bio
6. **Google Cloud Console → Billing → Budgets & alerts:** set a monthly budget alert at your comfort level.
7. **After the Android release:** on a device, `adb shell pm get-app-links com.code418.postbox_game` should show the domain as `verified`.
8. **Remote Config events:** for each event, edit `points_by_monarch`, publish, and put a calendar reminder to revert. Hold cypher-correction reviews for affected boxes until the event ends.
9. **If "Your Postboxes Unpacked" (PR #197) ships: release the app, then switch it on on 19 December.** The recap counts claims up to Friday 18 December, the last second-class posting day, and opens the next day.
   - **Before about 20 November:** get an app release that includes the recap live on both stores. The recap screen only exists in that release. The "your recap is ready" push also only goes to players who have it: it skips anyone whose app is older.
   - **Before 19 December (optional):** check the recap before players see it. In Google Cloud Console → Cloud Scheduler, force-run the `buildUnpacked` job (it counts the year so far), then open the recap in the app on an admin account.
   - **From 19 December** (the final recap data is built at 03:00): in Remote Config, set `unpacked_enabled` to true and publish. That shows the recap in the app. When you're happy with it, set `unpacked_notify_enabled` to true and publish. The push goes out once, at the next 10:00.
   - Change each flag's **default value**. The push ignores conditional values, so turning a flag on only for some users won't trigger it.

---

## 15. Open decisions

1. **Public support email.** `web/support.html` lists a personal address. Switch to the brand Gmail to keep the public face anonymous?
2. **Families with children.** "Family walks" is a strong angle (Victorians is a primary-school history topic), but targeting children has implications for age rating and consent. The current position is to market to adults, with families as a side benefit.
3. **Cosmetic referral badge** once badges ship (v1.8). Yes or no?
4. ~~**Android-first launch if iOS review drags.** Post on r/Postboxes with Android only after 2 November, or wait?~~ Resolved: iOS was approved on 3 November 2026.
5. **Named spokesperson for press burst 2 (the 175th)?** Press coverage would improve. Revisit in September 2027. **Partly settled 9 November 2026:** the LBSG and Postal Museum emails are signed by the owner by name, so outreach to organisations is no longer anonymous (a society newsletter may name the maker). Social accounts and press burst 1 can still use the brand Gmail; decision 1 (the support page's personal address) is worth settling to match.
6. **Custom domain.** Not free (about £10 a year). Revisit only if budget appears; the `web.app` domain works fine.

---

## Sources

- First British Isles pillar boxes, St Helier, Jersey, 23 November 1852: [Pillar box (Wikipedia)](https://en.wikipedia.org/wiki/Pillar_box); [Historic Post Boxes in Jersey, States of Jersey report (2014)](https://www.gov.je/SiteCollectionDocuments/Government%20and%20administration/Historic%20Post%20Boxes%20in%20Jersey%20report%202014.pdf)
- About 115,500 UK postboxes; the Letter Box Study Group (founded 1976): [LBSG: About us](https://lbsg.org/about-us/)
- Apple Featuring Nominations: [App Store Connect Help: Nominate your app for featuring](https://developer.apple.com/help/app-store-connect/manage-featuring-nominations/nominate-your-app-for-featuring/)
- Postbox counts: the repo's OpenStreetMap export (`postboxes.json`), October 2026. Postbox data © OpenStreetMap contributors, ODbL.
