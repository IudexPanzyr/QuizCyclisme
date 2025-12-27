/// <reference types="@cloudflare/workers-types" />

export interface Env {
  DB: D1Database;
}

function corsHeaders() {
  return {
    "Access-Control-Allow-Origin": "*",
    "Access-Control-Allow-Methods": "GET,POST,OPTIONS",
    "Access-Control-Allow-Headers": "Content-Type",
  };
}

function json(data: unknown, status = 200, extraHeaders: Record<string, string> = {}) {
  return new Response(JSON.stringify(data), {
    status,
    headers: {
      "Content-Type": "application/json; charset=utf-8",
      ...corsHeaders(),
      ...extraHeaders,
    },
  });
}

async function readJsonSafe<T>(req: Request): Promise<T | null> {
  const text = await req.text();
  if (!text) return null;
  return JSON.parse(text) as T;
}

// ---------- Duel helpers ----------
function randCode6(): string {
  const alphabet = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789"; // sans 0/O/I/1
  let s = "";
  for (let i = 0; i < 6; i++) s += alphabet[Math.floor(Math.random() * alphabet.length)];
  return s;
}

async function ensurePlayerExists(env: Env, playerId: string): Promise<boolean> {
  const p = await env.DB.prepare(`SELECT id FROM players WHERE id=?1 LIMIT 1;`).bind(playerId).first();
  return !!p;
}

type DuelRow = {
  id: string;
  code: string;
  status: "lobby" | "active" | "finished";
  total: number;
  currentRound: number;
  roundStartedAt?: number | null;
  roundEndsAt?: number | null;
  roundDurationMs?: number | null;
};

const DEFAULT_ROUND_DURATION_MS = 15000;
const TIMEOUT_TEAM_ID = "__TIMEOUT__";

// Tick “autoritaire” : si le round est expiré, on timeout les joueurs manquants et on avance.
async function tickDuelById(env: Env, duelId: string): Promise<void> {
  // On limite le nombre de boucles au cas où quelqu’un laisse un duel tourner longtemps.
  for (let guard = 0; guard < 10; guard++) {
    const duel = await env.DB.prepare(`
      SELECT
        id,
        code,
        status,
        total,
        current_round AS currentRound,
        round_started_at AS roundStartedAt,
        round_ends_at AS roundEndsAt,
        round_duration_ms AS roundDurationMs
      FROM duels
      WHERE id=?1
      LIMIT 1;
    `).bind(duelId).first<DuelRow>();

    if (!duel) return;
    if (duel.status !== "active") return;

    const now = Date.now();
    const dur = Number(duel.roundDurationMs ?? DEFAULT_ROUND_DURATION_MS) || DEFAULT_ROUND_DURATION_MS;

    // Si roundEndsAt pas initialisé (ancien duel, ou start incomplet), on l’initialise.
    if (!duel.roundEndsAt) {
      await env.DB.prepare(`
        UPDATE duels
        SET round_started_at=?2, round_ends_at=?3, round_duration_ms=COALESCE(round_duration_ms, ?4)
        WHERE id=?1;
      `).bind(duel.id, now, now + dur, dur).run();
      return; // prochain poll fera le reste
    }

    // Pas expiré -> rien à faire
    if (now <= duel.roundEndsAt) return;

    // Expiré -> on met timeout pour les joueurs qui n’ont pas répondu à CE round
    await env.DB.prepare(`
      INSERT INTO duel_answers(duel_id, round_no, player_id, team_id, is_correct, answered_at)
      SELECT
        dp.duel_id,
        ?2 AS round_no,
        dp.player_id,
        NULL AS team_id,
        0 AS is_correct,
        ?3 AS answered_at
      FROM duel_players dp
      LEFT JOIN duel_answers da
        ON da.duel_id = dp.duel_id
      AND da.round_no = ?2
      AND da.player_id = dp.player_id
      WHERE dp.duel_id=?1
        AND da.player_id IS NULL;
    `).bind(duel.id, duel.currentRound, now).run();


    // Maintenant tout le monde a une réponse (ou timeout) -> on avance
    if (duel.currentRound >= duel.total) {
      await env.DB.prepare(`
        UPDATE duels
        SET status='finished', finished_at=?2
        WHERE id=?1;
      `).bind(duel.id, now).run();
      return;
    }

    await env.DB.prepare(`
      UPDATE duels
      SET current_round = current_round + 1,
          round_started_at=?2,
          round_ends_at=?3,
          round_duration_ms=COALESCE(round_duration_ms, ?4)
      WHERE id=?1;
    `).bind(duel.id, now, now + dur, dur).run();

    // continue la boucle : si le match a pris énormément de retard, on peut devoir timeout plusieurs rounds.
  }
}

async function tickDuelByCode(env: Env, code: string): Promise<void> {
  const row = await env.DB.prepare(`SELECT id FROM duels WHERE code=?1 LIMIT 1;`).bind(code).first<{ id: string }>();
  if (!row) return;
  await tickDuelById(env, row.id);
}

export default {
  async fetch(req: Request, env: Env): Promise<Response> {
    const url = new URL(req.url);

    // CORS preflight
    if (req.method === "OPTIONS") {
      return new Response(null, { status: 204, headers: corsHeaders() });
    }

    try {
      // (optionnel) racine: petite "doc"
      if (req.method === "GET" && url.pathname === "/") {
        return json({
          ok: true,
          routes: [
            "/health",
            "/teams",
            "/question",
            "/answer",
            "/player",
            "/attempt",
            "/leaderboard",
            "/duel/create",
            "/duel/join",
            "/duel/start",
            "/duel/{code}/state",
            "/duel/{code}/question",
            "/duel/{code}/answer",
          ],
        });
      }

      // Healthcheck
      if (req.method === "GET" && url.pathname === "/health") {
        return json({ ok: true });
      }

      // -------------------------
      // Quiz: teams / question / answer
      // -------------------------

      // Liste complète des équipes (pour dropdown)
      if (req.method === "GET" && url.pathname === "/teams") {
        const { results } = await env.DB.prepare(`
          SELECT
            t.id,
            t.name,
            t.jersey_url AS jerseyUrl,
            c.code AS categoryCode,
            c.name AS categoryName
          FROM teams t
          JOIN categories c ON c.id = t.category_id
          ORDER BY c.code ASC, t.name ASC;
        `).all();

        return json({ teams: results });
      }

      // Question aléatoire: renvoie un coureur (sans révéler l'équipe)
      // Supporte: /question?exclude=id1,id2,id3
      if (req.method === "GET" && url.pathname === "/question") {
        const excludeParam = (url.searchParams.get("exclude") ?? "").trim();
        const exclude = excludeParam
          ? excludeParam.split(",").map((s) => s.trim()).filter(Boolean)
          : [];

        if (exclude.length > 2000) {
          return json({ error: "Too many excluded ids" }, 400);
        }

        let sql = `
          SELECT r.id AS riderId, r.full_name AS riderName, r.nation AS nation
          FROM riders r
          JOIN rider_team_current rtc ON rtc.rider_id = r.id
        `;

        const params: any[] = [];

        if (exclude.length > 0) {
          const placeholders = exclude.map((_, i) => `?${i + 1}`).join(",");
          sql += ` WHERE r.id NOT IN (${placeholders}) `;
          params.push(...exclude);
        }

        sql += `
          ORDER BY RANDOM()
          LIMIT 1;
        `;

        const stmt = env.DB.prepare(sql);
        const row = exclude.length > 0 ? await stmt.bind(...params).first() : await stmt.first();

        if (!row) return json({ error: "No more riders available" }, 404);
        return json({ rider: row });
      }

      // Vérifier la réponse (anti-triche)
      if (req.method === "POST" && url.pathname === "/answer") {
        type Body = { riderId?: string; teamId?: string };
        const body = await readJsonSafe<Body>(req);

        const riderId = (body?.riderId ?? "").trim();
        const teamId = (body?.teamId ?? "").trim();

        if (!riderId || !teamId) {
          return json({ error: "Missing riderId or teamId" }, 400);
        }

        const correct = await env.DB.prepare(`
          SELECT
            rtc.team_id AS correctTeamId,
            t.name AS correctTeamName
          FROM rider_team_current rtc
          JOIN teams t ON t.id = rtc.team_id
          WHERE rtc.rider_id = ?1
          LIMIT 1;
        `).bind(riderId).first<{
          correctTeamId: string;
          correctTeamName: string;
        }>();

        if (!correct) return json({ error: "Unknown riderId" }, 404);

        const isCorrect = correct.correctTeamId === teamId;

        return json({
          correct: isCorrect,
          correctTeamId: correct.correctTeamId,
          correctTeamName: correct.correctTeamName,
        });
      }

      // -------------------------
      // Players + Attempts + Leaderboard
      // -------------------------

      // Create or update a player (pseudo)
      if (req.method === "POST" && url.pathname === "/player") {
        type Body = { playerId?: string; name?: string };
        const body = await readJsonSafe<Body>(req);

        const nameRaw = (body?.name ?? "").trim();
        const name = nameRaw.slice(0, 24);

        if (name.length < 2) {
          return json({ error: "Name too short" }, 400);
        }

        const now = Date.now();
        const playerId =
          body?.playerId && body.playerId.trim() ? body.playerId.trim() : crypto.randomUUID();

        await env.DB.prepare(`
          INSERT INTO players(id, name, created_at, updated_at)
          VALUES(?1, ?2, ?3, ?3)
          ON CONFLICT(id) DO UPDATE SET
            name = excluded.name,
            updated_at = excluded.updated_at;
        `).bind(playerId, name, now).run();

        return json({ playerId, name });
      }

      // Save a session attempt (score out of total)
      if (req.method === "POST" && url.pathname === "/attempt") {
        type Body = { playerId?: string; score?: number; total?: number };
        const body = await readJsonSafe<Body>(req);

        const playerId = (body?.playerId ?? "").trim();
        const score = Number(body?.score);
        const total = Number(body?.total);

        if (!playerId) return json({ error: "Missing playerId" }, 400);
        if (!Number.isFinite(score) || !Number.isFinite(total)) {
          return json({ error: "Invalid score/total" }, 400);
        }
        if (total <= 0 || score < 0 || score > total) {
          return json({ error: "Score out of range" }, 400);
        }

        const p = await env.DB.prepare(`SELECT id FROM players WHERE id=?1 LIMIT 1;`)
          .bind(playerId)
          .first();
        if (!p) return json({ error: "Unknown playerId" }, 404);

        const now = Date.now();
        const attemptId = crypto.randomUUID();

        await env.DB.prepare(`
          INSERT INTO attempts(id, player_id, score, total, created_at)
          VALUES(?1, ?2, ?3, ?4, ?5);
        `).bind(attemptId, playerId, score, total, now).run();

        return json({ ok: true, attemptId });
      }

      // Leaderboard (best score per player)
      if (req.method === "GET" && url.pathname === "/leaderboard") {
        const totalParam = url.searchParams.get("total");
        const limitParam = url.searchParams.get("limit");

        const total = totalParam ? Number(totalParam) : 30;
        const limit = limitParam ? Math.min(200, Math.max(1, Number(limitParam))) : 50;

        if (!Number.isFinite(total) || total <= 0) return json({ error: "Invalid total" }, 400);

        const { results } = await env.DB.prepare(`
          SELECT
            p.id AS playerId,
            p.name AS name,
            MAX(a.score) AS bestScore,
            ?1 AS total,
            COUNT(a.id) AS plays,
            MAX(a.created_at) AS lastPlayed
          FROM players p
          JOIN attempts a ON a.player_id = p.id
          WHERE a.total = ?1
          GROUP BY p.id
          ORDER BY bestScore DESC, lastPlayed ASC
          LIMIT ?2;
        `).bind(total, limit).all();

        return json({ leaderboard: results });
      }

      // -------------------------
      // Duels (polling) + Timer serveur
      // -------------------------

      // Create duel lobby -> returns {code}
      if (req.method === "POST" && url.pathname === "/duel/create") {
        type Body = { playerId?: string; total?: number; roundSeconds?: number };
        const body = await readJsonSafe<Body>(req);

        const playerId = (body?.playerId ?? "").trim();
        const total = body?.total ? Number(body.total) : 30;

        // Optionnel: roundSeconds (par défaut 15)
        const roundSecondsRaw = body?.roundSeconds ? Number(body.roundSeconds) : 15;
        const roundDurationMs = Math.min(60, Math.max(5, roundSecondsRaw)) * 1000;

        if (!playerId) return json({ error: "Missing playerId" }, 400);
        if (!Number.isFinite(total) || total < 5 || total > 50) {
          return json({ error: "Invalid total (5..50)" }, 400);
        }

        if (!(await ensurePlayerExists(env, playerId))) return json({ error: "Unknown playerId" }, 404);

        // code unique
        let code = "";
        for (let i = 0; i < 10; i++) {
          const c = randCode6();
          const exists = await env.DB.prepare(`SELECT 1 FROM duels WHERE code=?1 LIMIT 1;`)
            .bind(c)
            .first();
          if (!exists) {
            code = c;
            break;
          }
        }
        if (!code) return json({ error: "Could not generate code" }, 500);

        const duelId = crypto.randomUUID();
        const now = Date.now();

        await env.DB.prepare(`
          INSERT INTO duels(id, code, status, total, current_round, created_at, round_duration_ms)
          VALUES(?1, ?2, 'lobby', ?3, 1, ?4, ?5);
        `).bind(duelId, code, total, now, roundDurationMs).run();

        // host = side 1
        await env.DB.prepare(`
          INSERT INTO duel_players(duel_id, player_id, joined_at, side)
          VALUES(?1, ?2, ?3, 1);
        `).bind(duelId, playerId, now).run();

        return json({ duelId, code, status: "lobby", total, roundDurationMs });
      }

      // Join duel lobby (NE démarre plus automatiquement)
      if (req.method === "POST" && url.pathname === "/duel/join") {
        type Body = { playerId?: string; code?: string };
        const body = await readJsonSafe<Body>(req);

        const playerId = (body?.playerId ?? "").trim();
        const code = (body?.code ?? "").trim().toUpperCase();

        if (!playerId || !code) return json({ error: "Missing playerId or code" }, 400);
        if (!(await ensurePlayerExists(env, playerId))) return json({ error: "Unknown playerId" }, 404);

        const duel = await env.DB.prepare(`
          SELECT id, status, total FROM duels WHERE code=?1 LIMIT 1;
        `).bind(code).first<{ id: string; status: string; total: number }>();

        if (!duel) return json({ error: "Unknown code" }, 404);
        if (duel.status !== "lobby") return json({ error: "Duel not joinable" }, 400);

        const now = Date.now();

        // déjà dedans ?
        const already = await env.DB.prepare(`
          SELECT 1 FROM duel_players WHERE duel_id=?1 AND player_id=?2 LIMIT 1;
        `).bind(duel.id, playerId).first();

        if (!already) {
          const countRow = await env.DB.prepare(`
            SELECT COUNT(*) AS c FROM duel_players WHERE duel_id=?1;
          `).bind(duel.id).first<{ c: number }>();

          const count = Number(countRow?.c ?? 0);
          if (count >= 2) return json({ error: "Lobby full" }, 400);

          await env.DB.prepare(`
            INSERT INTO duel_players(duel_id, player_id, joined_at, side)
            VALUES(?1, ?2, ?3, 2);
          `).bind(duel.id, playerId, now).run();
        }

        return json({ ok: true, code, status: "lobby" });
      }

      // Host starts duel -> generate rounds + status=active + init timer serveur
      if (req.method === "POST" && url.pathname === "/duel/start") {
        type Body = { playerId?: string; code?: string };
        const body = await readJsonSafe<Body>(req);

        const playerId = (body?.playerId ?? "").trim();
        const code = (body?.code ?? "").trim().toUpperCase();

        if (!playerId || !code) return json({ error: "Missing playerId or code" }, 400);
        if (!(await ensurePlayerExists(env, playerId))) return json({ error: "Unknown playerId" }, 404);

        const duel = await env.DB.prepare(`
          SELECT id, status, total, round_duration_ms AS roundDurationMs
          FROM duels WHERE code=?1 LIMIT 1;
        `).bind(code).first<any>();

        if (!duel) return json({ error: "Unknown code" }, 404);
        if (duel.status !== "lobby") return json({ error: "Duel already started" }, 400);

        // Host = side=1
        const host = await env.DB.prepare(`
          SELECT 1
          FROM duel_players
          WHERE duel_id=?1 AND player_id=?2 AND side=1
          LIMIT 1;
        `).bind(duel.id, playerId).first();

        if (!host) return json({ error: "Only host can start" }, 403);

        // Need 2 players
        const countRow = await env.DB.prepare(`
          SELECT COUNT(*) AS c FROM duel_players WHERE duel_id=?1;
        `).bind(duel.id).first<{ c: number }>();

        const count = Number(countRow?.c ?? 0);
        if (count < 2) return json({ error: "Need 2 players to start" }, 400);

        // Prevent double init
        const alreadyRounds = await env.DB.prepare(`
          SELECT 1 FROM duel_rounds WHERE duel_id=?1 LIMIT 1;
        `).bind(duel.id).first();
        if (alreadyRounds) return json({ error: "Duel already initialized" }, 400);

        // Generate N rounds (riders uniques)
        const rows = await env.DB.prepare(`
          SELECT r.id AS riderId, rtc.team_id AS correctTeamId
          FROM riders r
          JOIN rider_team_current rtc ON rtc.rider_id = r.id
          ORDER BY RANDOM()
          LIMIT ?1;
        `).bind(duel.total).all<{ riderId: string; correctTeamId: string }>();

        const list = rows.results ?? [];
        if (list.length < duel.total) return json({ error: "Not enough riders in DB" }, 500);

        for (let i = 0; i < list.length; i++) {
          await env.DB.prepare(`
            INSERT INTO duel_rounds(duel_id, round_no, rider_id, correct_team_id)
            VALUES(?1, ?2, ?3, ?4);
          `).bind(duel.id, i + 1, list[i].riderId, list[i].correctTeamId).run();
        }

        const now = Date.now();
        const dur = Number(duel.roundDurationMs ?? DEFAULT_ROUND_DURATION_MS) || DEFAULT_ROUND_DURATION_MS;

        await env.DB.prepare(`
          UPDATE duels
          SET status='active',
              started_at=?2,
              current_round=1,
              round_started_at=?2,
              round_ends_at=?3,
              round_duration_ms=COALESCE(round_duration_ms, ?4)
          WHERE id=?1;
        `).bind(duel.id, now, now + dur, dur).run();

        return json({ ok: true, status: "active", roundEndsAt: now + dur, roundDurationMs: dur, serverTime: now });
      }

      // -------- Dynamic duel routes: /duel/{code}/... --------
      const parts = url.pathname.split("/").filter(Boolean);

      // GET /duel/{code}/state?playerId=...
      if (req.method === "GET" && parts.length === 3 && parts[0] === "duel" && parts[2] === "state") {
        const code = parts[1].toUpperCase();
        const playerId = (url.searchParams.get("playerId") ?? "").trim();
        if (!code || !playerId) return json({ error: "Missing code or playerId" }, 400);

        // Timer serveur : applique les timeouts / avance si nécessaire
        await tickDuelByCode(env, code);

        const duel = await env.DB.prepare(`
          SELECT
            id,
            code,
            status,
            total,
            current_round AS currentRound,
            round_started_at AS roundStartedAt,
            round_ends_at AS roundEndsAt,
            round_duration_ms AS roundDurationMs
          FROM duels WHERE code=?1 LIMIT 1;
        `).bind(code).first<DuelRow>();

        if (!duel) return json({ error: "Unknown code" }, 404);

        const playersRes = await env.DB.prepare(`
          SELECT dp.player_id AS playerId, p.name AS name, dp.side AS side
          FROM duel_players dp
          JOIN players p ON p.id = dp.player_id
          WHERE dp.duel_id=?1
          ORDER BY dp.side ASC;
        `).bind(duel.id).all();

        const scoresRes = await env.DB.prepare(`
          SELECT
            dp.player_id AS playerId,
            SUM(CASE WHEN da.is_correct=1 THEN 1 ELSE 0 END) AS score
          FROM duel_players dp
          LEFT JOIN duel_answers da
            ON da.duel_id = dp.duel_id AND da.player_id = dp.player_id
          WHERE dp.duel_id=?1
          GROUP BY dp.player_id
          ORDER BY MIN(dp.side) ASC;
        `).bind(duel.id).all();

        const myAns = await env.DB.prepare(`
          SELECT 1 FROM duel_answers
          WHERE duel_id=?1 AND round_no=?2 AND player_id=?3
          LIMIT 1;
        `).bind(duel.id, duel.currentRound, playerId).first();

        const answeredCount = await env.DB.prepare(`
          SELECT COUNT(*) AS c FROM duel_answers
          WHERE duel_id=?1 AND round_no=?2;
        `).bind(duel.id, duel.currentRound).first<{ c: number }>();

        // ---- Result (finished) + store in duel_results ----
        let result: any = null;

        if (duel.status === "finished") {
          const sideScores = await env.DB.prepare(`
            SELECT
              dp.side AS side,
              dp.player_id AS playerId,
              p.name AS name,
              SUM(CASE WHEN da.is_correct=1 THEN 1 ELSE 0 END) AS score
            FROM duel_players dp
            JOIN players p ON p.id = dp.player_id
            LEFT JOIN duel_answers da
              ON da.duel_id = dp.duel_id AND da.player_id = dp.player_id
            WHERE dp.duel_id=?1
            GROUP BY dp.side, dp.player_id
            ORDER BY dp.side ASC;
          `).bind(duel.id).all();

          const rows = (sideScores.results ?? []) as any[];
          const p1 = rows.find((r) => Number(r.side) === 1);
          const p2 = rows.find((r) => Number(r.side) === 2);

          const p1Score = Number(p1?.score ?? 0);
          const p2Score = Number(p2?.score ?? 0);

          let winnerPlayerId: string | null = null;
          if (p1Score > p2Score) winnerPlayerId = p1?.playerId ?? null;
          else if (p2Score > p1Score) winnerPlayerId = p2?.playerId ?? null;

          await env.DB.prepare(`
            INSERT INTO duel_results(duel_id, winner_player_id, p1_score, p2_score, total, created_at)
            VALUES(?1, ?2, ?3, ?4, ?5, ?6)
            ON CONFLICT(duel_id) DO UPDATE SET
              winner_player_id=excluded.winner_player_id,
              p1_score=excluded.p1_score,
              p2_score=excluded.p2_score,
              total=excluded.total;
          `).bind(duel.id, winnerPlayerId, p1Score, p2Score, duel.total, Date.now()).run();

          result = {
            p1: { playerId: p1?.playerId, name: p1?.name, score: p1Score },
            p2: { playerId: p2?.playerId, name: p2?.name, score: p2Score },
            winnerPlayerId,
            total: duel.total,
          };
        }

        const now = Date.now();

        return json({
          serverTime: now,
          duel: {
            code: duel.code,
            status: duel.status,
            total: duel.total,
            currentRound: duel.currentRound,
            roundStartedAt: duel.roundStartedAt ?? null,
            roundEndsAt: duel.roundEndsAt ?? null,
            roundDurationMs: duel.roundDurationMs ?? DEFAULT_ROUND_DURATION_MS,
          },
          players: playersRes.results,
          scores: scoresRes.results,
          me: { playerId, answeredThisRound: !!myAns },
          round: { answeredCount: Number(answeredCount?.c ?? 0) },
          result,
        });
      }

      // GET /duel/{code}/question?playerId=...
      if (req.method === "GET" && parts.length === 3 && parts[0] === "duel" && parts[2] === "question") {
        const code = parts[1].toUpperCase();
        const playerId = (url.searchParams.get("playerId") ?? "").trim();
        if (!code || !playerId) return json({ error: "Missing code or playerId" }, 400);

        await tickDuelByCode(env, code);

        const duel = await env.DB.prepare(`
          SELECT
            id,
            status,
            total,
            current_round AS currentRound,
            round_ends_at AS roundEndsAt,
            round_duration_ms AS roundDurationMs
          FROM duels WHERE code=?1 LIMIT 1;
        `).bind(code).first<any>();

        if (!duel) return json({ error: "Unknown code" }, 404);
        if (duel.status === "lobby") return json({ waiting: true, status: "lobby" });
        if (duel.status === "finished") return json({ finished: true, status: "finished" });

        const round = await env.DB.prepare(`
          SELECT dr.round_no AS roundNo, r.id AS riderId, r.full_name AS riderName, r.nation AS nation
          FROM duel_rounds dr
          JOIN riders r ON r.id = dr.rider_id
          WHERE dr.duel_id=?1 AND dr.round_no=?2
          LIMIT 1;
        `).bind(duel.id, duel.currentRound).first();

        if (!round) return json({ error: "Round not found" }, 404);

        return json({
          serverTime: Date.now(),
          roundEndsAt: duel.roundEndsAt ?? null,
          roundDurationMs: duel.roundDurationMs ?? DEFAULT_ROUND_DURATION_MS,
          round,
        });
      }

      // POST /duel/{code}/answer
      if (req.method === "POST" && parts.length === 3 && parts[0] === "duel" && parts[2] === "answer") {
        const code = parts[1].toUpperCase();

        type Body = { playerId?: string; teamId?: string; roundNo?: number };
        const body = await readJsonSafe<Body>(req);

        const playerId = (body?.playerId ?? "").trim();
        const teamIdRaw = (body?.teamId ?? "").trim();
        const clientRoundNo = body?.roundNo != null ? Number(body.roundNo) : null;

        if (!code || !playerId || !teamIdRaw) {
          return json({ error: "Missing code/playerId/teamId" }, 400);
        }

        await tickDuelByCode(env, code);

        const duel = await env.DB.prepare(`
          SELECT
            id, status, total, current_round AS currentRound,
            round_ends_at AS roundEndsAt,
            round_duration_ms AS roundDurationMs
          FROM duels WHERE code=?1 LIMIT 1;
        `).bind(code).first<any>();

        if (!duel) return json({ error: "Unknown code" }, 404);
        if (duel.status !== "active") return json({ error: "Duel not active" }, 400);

        // Si le client envoie roundNo, on protège contre les réponses “en retard” sur un mauvais round
        if (clientRoundNo != null && Number.isFinite(clientRoundNo) && clientRoundNo !== duel.currentRound) {
          return json({ error: "Stale round", currentRound: duel.currentRound }, 409);
        }

        const inDuel = await env.DB.prepare(`
          SELECT 1 FROM duel_players WHERE duel_id=?1 AND player_id=?2 LIMIT 1;
        `).bind(duel.id, playerId).first();
        if (!inDuel) return json({ error: "Player not in duel" }, 403);

        const r = await env.DB.prepare(`
          SELECT dr.correct_team_id AS correctTeamId, t.name AS correctTeamName
          FROM duel_rounds dr
          JOIN teams t ON t.id = dr.correct_team_id
          WHERE dr.duel_id=?1 AND dr.round_no=?2
          LIMIT 1;
        `).bind(duel.id, duel.currentRound).first<{ correctTeamId: string; correctTeamName: string }>();

        if (!r) return json({ error: "Round not found" }, 404);

        const now = Date.now();
        const roundEndsAt = Number(duel.roundEndsAt ?? 0);

        // Si expiré côté serveur -> réponse devient timeout (même si le client envoie autre chose)
        const expired = roundEndsAt > 0 && now > roundEndsAt;

        const clientWantsTimeout = teamIdRaw === TIMEOUT_TEAM_ID;
        const isTimeout = expired || clientWantsTimeout;

        const effectiveTeamId: string | null = isTimeout ? null : teamIdRaw;
        const isCorrect = !isTimeout && (r.correctTeamId === effectiveTeamId);

        // Insert answer. If already answered, primary key will conflict.
        try {
          await env.DB.prepare(`
            INSERT INTO duel_answers(duel_id, round_no, player_id, team_id, is_correct, answered_at)
            VALUES(?1, ?2, ?3, ?4, ?5, ?6);
          `).bind(duel.id, duel.currentRound, playerId, effectiveTeamId, isCorrect ? 1 : 0, now).run();

        } catch {
          return json({ error: "Already answered this round" }, 400);
        }

        // Après une réponse, on retick tout de suite : si l’autre a déjà répondu, ça avance instantanément.
        await tickDuelById(env, duel.id);

        return json({
          ok: true,
          correct: isCorrect,
          correctTeamName: r.correctTeamName,
          timeout: isTimeout,
          expired,
          serverTime: Date.now(),
        });
      }

      return json({ error: "Not found" }, 404);
    } catch (e: any) {
      return json({ error: e?.message ?? "Server error" }, 500);
    }
  },
};
