# Unicycle Bros 3D — Netlify + Supabase Online Edition

This package adds shared online accounts/cloud saves, case-insensitive unique usernames, searchable profiles, friend requests, online presence, friend challenges, six-player private rooms with 9-digit codes, and public matchmaking. It keeps the original HTML/Three.js game and existing local guest profiles.

**Public matchmaking policy:** a public match starts when at least **4 of 6** player slots are occupied. The game searches for up to 25 seconds; otherwise it removes the waiting player and shows the exact message **“No Unoccupied Servers Found”**. Private host rooms can start with at least two players.

## What you need

- - A Netlify account. Netlify currently lists a $0 Free plan with Functions, subject to its monthly usage-credit limit.
- A Supabase project. The Free plan includes database, Auth, and Realtime quotas, but projects can pause after a week of inactivity. Check the providers’ current usage limits before sharing the game widely.
- A GitHub repository connected to Netlify. This version uses a Netlify Function for username/password login, so deploy the complete project root, not just the static `public` folder.

Relevant official docs:
- Netlify Git deploy: <https://docs.netlify.com/start/quickstarts/deploy-from-repository/>
- Netlify Function environment variables: <https://docs.netlify.com/build/functions/environment-variables/>
- Supabase JavaScript client: <https://supabase.com/docs/reference/javascript/installing>
- Supabase Auth: <https://supabase.com/docs/guides/auth>

## Step 1 — Create the database

1. Create a new project at <https://supabase.com/dashboard>.
2. Open **SQL Editor → New query**.
3. Open `supabase/schema.sql` from this package, copy the entire file into the editor, and run it.
4. The script creates the profile/save tables, unique username index, friendship requests, challenges, room tables, row-level security policies, and checked RPC functions.
5. Keep email confirmation enabled. New accounts use an email for confirmation; the email itself is never shown in public profile searches.

Run this SQL in a new/dedicated Supabase project for this game. If you rerun it later after editing the schema, review Supabase SQL errors rather than assuming every existing table was modified by `create table if not exists`.

## Step 2 — Put your public Supabase values into the website

1. In Supabase, open **Project Settings → API** (the exact menu label can vary).
2. Copy the **Project URL**.
3. Copy the **publishable key** (or legacy anon/public key). This key is intended for browser use; database RLS policies restrict its access.
4. Edit `public/online-config.js` and replace these two placeholder values:

```js
window.UNICY_BROS_CONFIG = {
  supabaseUrl: 'https://YOUR-PROJECT-REF.supabase.co',
  supabaseAnonKey: 'YOUR_SUPABASE_PUBLISHABLE_OR_ANON_KEY'
};
```

Do not put the **service_role/secret key** in this file or in `index.html`.

## Step 3 — Configure Supabase email redirects

After you deploy to Netlify and receive your site URL:

1. In Supabase, open **Authentication → URL Configuration**.
2. Set **Site URL** to your deployed Netlify URL, for example `https://your-site-name.netlify.app`.
3. Add that same URL to the allowed **Redirect URLs** list. Add your Netlify deploy-preview URL only if you plan to test previews.

The user signs up with a unique username, email, and password. They confirm email, then log in with their **username and password**. Username matching is case-insensitive; a database uniqueness constraint prevents `Racer` and `racer` from being registered as different usernames.

## Step 4 — Configure Netlify's server-only variables

The username-login Function uses the service key only on Netlify's server. In Netlify, open your site → **Site configuration → Environment variables** and add these values:

| Variable | Value |
| --- | --- |
| `SUPABASE_URL` | Same project URL as Step 2 |
| `SUPABASE_ANON_KEY` | Same publishable/anon key as Step 2 |
| `SUPABASE_SERVICE_ROLE_KEY` | Supabase secret/service-role key, server-side only |

Set their scope so they are available to **Functions** at runtime. Never write `SUPABASE_SERVICE_ROLE_KEY` into any public file or commit it to GitHub. Netlify environment-variable changes require a new deploy before the Function uses the new values.

## Step 5 — Deploy on Netlify

1. Create a repository on GitHub and upload the contents of this package (the `public` folder, `netlify` folder, `supabase` folder, `netlify.toml`, and `package.json`) to its root.
2. In Netlify, choose **Add new project → Import an existing project**, connect GitHub, and choose that repository.
3. Use the included `netlify.toml` settings: base directory `.` (the repository root), an empty build command, publish directory `public`, and functions directory `netlify/functions`. These explicit settings override any stale values saved in Netlify. There is no frontend build command required; Netlify installs the function dependency from `package.json`. If entering settings in the Netlify dashboard, leave the base directory and build command blank; do not enter `npm run build` as a directory.
4. Deploy and open the provided `.netlify.app` URL.
5. Create an account using a real email you control, confirm the email, and sign in with your username and password.

Uploading only the `public` folder would omit the `login-by-username` Function, `netlify.toml`, and function dependency. Use a Git-connected Netlify project with the full package root so the site and Function are deployed together.

For local or automated CLI deploys, run `npm ci` from the repository root before `netlify deploy`. The CLI needs the installed function dependency when bundling `login-by-username`; declaring it in `package.json` alone does not install it. Keep `package-lock.json` in the repository for repeatable dependency installation.

## Features in this build

- Online account registration with verified email, username/password login, case-insensitive unique usernames, and cross-device game-save syncing.
- Public profile search and friend requests (accept/decline/remove).
- Presence status refreshed while users have the game open; friend challenges are only sent to friends seen online recently.
- Private rooms with unique 9-digit codes; up to six users; the host starts the race after at least one other player has joined.
- Public matchmaking puts players into an open room, requires four of six players to begin, and times out after 25 seconds with **No Unoccupied Servers Found**.
- Online race positions are broadcast over Supabase Realtime, using the same deterministic course and the players' selected rider/cosmetics.
- Bot races award half the normal coin payout; online races use the normal local game payout.
- Guest profiles continue saving locally on the current browser.

## Important limits

This is a working online prototype, not an authoritative competitive game server. Player positions are live-synchronized, but each browser still simulates some racing and coin/gameplay outcomes locally. Do not use it for valuable trades or competitive rankings yet. Server-authoritative rewards, trading/anti-cheat, rematch/room recovery, and moderation/reporting are future work. Online racing requires a stable internet connection and Supabase Realtime; normal bot races can still be used without signing in.

## Troubleshooting

- **“Online setup is not complete”**: check `public/online-config.js` contains the correct project URL and public key.
- **Login fails with a network/function error**: make sure the site is deployed through Git and the three Netlify environment variables are set with Function scope, then redeploy.
- **Email-confirmation link fails**: add the exact `.netlify.app` URL to Supabase's allowed redirect URLs.
- **Username already taken**: usernames are unique regardless of uppercase/lowercase.
- **Public matchmaking fails**: it needs four players in the 25-second window. Test private rooms with two accounts/devices first.
