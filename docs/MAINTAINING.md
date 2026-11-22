# Maintaining the official Sidesnap

These notes are for the maintainer of the official app. Forks don't need
any of this.

## Repos

- **Public:** `b02872626-ctrl/sidesnap` (this repo) holds the app and the
  download page. Every commit here is public.
- **Private:** `b02872626-ctrl/sidesnap-private` holds the old full history
  (from when the app was called Snapshelf). Nothing new goes there.
- On the Mac, the folder is `14. Snapshelf`. `origin` is the public repo,
  `private` is the private one.
- Commits here are made under the name "Sidesnap" with GitHub's no-reply
  email (set in this clone's git config), so no personal name or email goes
  public.

## Releasing an update

1. Add a `## <version>` section with `- ` bullet points at the top of
   `RELEASE_NOTES.md`. Users see these in the update window.
2. Run `./publish.sh`. It:
   - refuses to run if `Sources/` or `Resources/` have uncommitted changes,
     or if that version was already published
   - builds for Apple silicon and Intel, and signs with the
     "Sidesnap Developer" certificate (it refuses to build without it)
   - signs the update with the Sparkle key and writes `site/appcast.xml`
   - deploys the site to Cloudflare and checks that the live files match
     the build
   - commits, tags `v<version>` and pushes.

   `./publish.sh --dry-run` builds everything but deploys and commits
   nothing.

## Website and download count

- Live at https://sidesnap.typewellapp.workers.dev (Cloudflare Worker
  `sidesnap`, files in `site/`, code in `worker/index.js`).
- Downloads are counted per day in the D1 database `sidesnap-stats`. No
  visitor data is stored.
- `/admin` shows the counts. Set its password once with
  `npx wrangler secret put ADMIN_PASSWORD`.
- To change only the page (no new app version): edit `site/`, then
  `npx wrangler deploy`, then commit.

## Keys and backups

Two secrets live only in this Mac's login keychain. Without them you can't
ship updates that install themselves and keep users' Screen Recording
permission. Back both up somewhere safe, such as a password manager or an
encrypted USB drive. Never put them in this repo.

1. **Signing certificate "Sidesnap Developer"** (makes macOS treat every
   version as the same app):
   - Keychain Access › login › My Certificates.
   - Right-click "Sidesnap Developer" › Export › save as `.p12` with a
     strong password.
   - To restore on a new Mac, double-click the `.p12`.
2. **Update key** (Sidesnap only installs updates signed with it):
   - `Vendor/Sparkle-2.10.1/bin/generate_keys --account sidesnap -x sidesnap-update-key.txt`
     writes it to a file. Store that file safely, then delete it.
   - To restore: `generate_keys --account sidesnap -f sidesnap-update-key.txt`.

## Pull requests

PRs aren't accepted (see CONTRIBUTING.md). Close them politely and point to
the template message.
