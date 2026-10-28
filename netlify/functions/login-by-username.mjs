import { createClient } from '@supabase/supabase-js';

const json = (statusCode, body) => ({
  statusCode,
  headers: { 'Content-Type': 'application/json; charset=utf-8', 'Cache-Control': 'no-store' },
  body: JSON.stringify(body)
});

export async function handler(event) {
  if (event.httpMethod !== 'POST') return json(405, { error: 'Method not allowed.' });
  const url = process.env.SUPABASE_URL;
  const anonKey = process.env.SUPABASE_ANON_KEY;
  const serviceKey = process.env.SUPABASE_SERVICE_ROLE_KEY;
  if (!url || !anonKey || !serviceKey) return json(500, { error: 'Server auth is not configured. Check Netlify environment variables.' });

  let input;
  try { input = JSON.parse(event.body || '{}'); }
  catch { return json(400, { error: 'Invalid request.' }); }

  const username = String(input.username || '').trim();
  const password = String(input.password || '');
  if (!/^[A-Za-z0-9_]{3,16}$/.test(username) || password.length < 8 || password.length > 128) {
    return json(400, { error: 'Enter your username and password.' });
  }

  try {
    const admin = createClient(url, serviceKey, { auth: { persistSession: false, autoRefreshToken: false } });
    const publicAuth = createClient(url, anonKey, { auth: { persistSession: false, autoRefreshToken: false, detectSessionInUrl: false } });

    // The user-facing response never reveals whether the username or password was wrong.
    const { data: profile, error: profileError } = await admin
      .from('profiles').select('id,username').eq('username_lower', username.toLowerCase()).maybeSingle();
    if (profileError || !profile) return json(401, { error: 'Invalid username or password.' });

    const { data: userResult, error: userError } = await admin.auth.admin.getUserById(profile.id);
    const email = userResult?.user?.email;
    if (userError || !email) return json(401, { error: 'Invalid username or password.' });

    const { data, error } = await publicAuth.auth.signInWithPassword({ email, password });
    if (error || !data?.session) return json(401, { error: 'Invalid username or password.' });
    return json(200, {
      session: data.session,
      user: { id: profile.id, username: profile.username }
    });
  } catch (error) {
    console.error('username login failed', error?.message || error);
    return json(500, { error: 'Login is temporarily unavailable. Please try again.' });
  }
}
