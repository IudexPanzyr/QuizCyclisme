import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'config.dart';
import 'duel_page.dart';


const int sessionTotal = 30;

void main() {
  runApp(const CyclingQuizApp());
}

class CyclingQuizApp extends StatelessWidget {
  const CyclingQuizApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Cycling Quiz',
      theme: ThemeData(useMaterial3: true, colorSchemeSeed: Colors.blue),
      home: const HomePage(),
    );
  }
}

class PlayerInfo {
  final String playerId;
  final String name;

  PlayerInfo({required this.playerId, required this.name});
}

/// -------- HOME PAGE (choix Solo / Duels + init player) --------

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  bool loading = true;
  String? error;

  PlayerInfo? player;

  @override
  void initState() {
    super.initState();
    _boot();
  }

  Future<void> _boot() async {
    setState(() {
      loading = true;
      error = null;
    });

    try {
      player = await ensurePlayer(context);
    } catch (e) {
      error = e.toString();
    } finally {
      setState(() => loading = false);
    }
  }

  Future<void> _changePseudo() async {
    if (player == null) return;

    final newName = await askPseudoDialog(context, title: "Nouveau pseudo");
    if (newName == null) return;

    setState(() => loading = true);

    try {
      final updated = await createOrUpdatePlayer(
        playerId: player!.playerId,
        name: newName,
      );

      player = PlayerInfo(playerId: updated.playerId, name: updated.name);

      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('playerId', player!.playerId);
      await prefs.setString('playerName', player!.name);

      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text("Pseudo mis à jour ✅")),
      );
    } catch (e) {
      setState(() => error = e.toString());
    } finally {
      setState(() => loading = false);
    }
  }

  void _openSolo() {
    final p = player;
    if (p == null) return;

    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => QuizPage(
          playerId: p.playerId,
          playerName: p.name,
          onPlayerUpdated: (newName) async {
            final updated = await createOrUpdatePlayer(playerId: p.playerId, name: newName);
            final prefs = await SharedPreferences.getInstance();
            await prefs.setString('playerId', updated.playerId);
            await prefs.setString('playerName', updated.name);
            setState(() {
              player = PlayerInfo(playerId: updated.playerId, name: updated.name);
            });
            return PlayerInfo(playerId: updated.playerId, name: updated.name);
          },
        ),
      ),
    );
  }

  void _openDuels() {
    final p = player;
    if (p == null) return;

    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => DuelPage(
          apiBase: apiBase,
          playerId: p.playerId,
          playerName: p.name,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final p = player;

    return Scaffold(
      appBar: AppBar(
        title: const Text("Cycling Quiz"),
        actions: [
          if (p != null)
            TextButton(
              onPressed: loading ? null : _changePseudo,
              child: Text(
                p.name,
                style: const TextStyle(color: Colors.white),
              ),
            ),
        ],
      ),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 420),
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: loading
                ? const Center(child: CircularProgressIndicator())
                : Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      if (error != null) ...[
                        Text(error!, style: const TextStyle(color: Colors.red)),
                        const SizedBox(height: 12),
                      ],
                      Text(
                        "Choisis un mode",
                        textAlign: TextAlign.center,
                        style: Theme.of(context).textTheme.headlineSmall,
                      ),
                      const SizedBox(height: 18),

                      FilledButton.icon(
                        icon: const Icon(Icons.person),
                        label: const Padding(
                          padding: EdgeInsets.symmetric(vertical: 14),
                          child: Text("Solo"),
                        ),
                        onPressed: (p == null) ? null : _openSolo,
                      ),

                      const SizedBox(height: 12),

                      FilledButton.icon(
                        icon: const Icon(Icons.sports_kabaddi),
                        label: const Padding(
                          padding: EdgeInsets.symmetric(vertical: 14),
                          child: Text("Duels"),
                        ),
                        onPressed: (p == null) ? null : _openDuels,
                      ),

                      const SizedBox(height: 18),
                      Text(
                        "Pseudo: ${p?.name ?? '—'}",
                        textAlign: TextAlign.center,
                      ),
                    ],
                  ),
          ),
        ),
      ),
    );
  }
}

/// -------- SOLO QUIZ PAGE --------

class Team {
  final String id;
  final String name;
  final String categoryCode;
  final String? jerseyUrl;

  Team({
    required this.id,
    required this.name,
    required this.categoryCode,
    required this.jerseyUrl,
  });

  factory Team.fromJson(Map<String, dynamic> j) => Team(
        id: j['id'] as String,
        name: j['name'] as String,
        categoryCode: (j['categoryCode'] as String?) ?? '',
        jerseyUrl: j['jerseyUrl'] as String?,
      );
}

class RiderQuestion {
  final String riderId;
  final String riderName;
  final String? nation;

  RiderQuestion({
    required this.riderId,
    required this.riderName,
    required this.nation,
  });

  factory RiderQuestion.fromJson(Map<String, dynamic> j) => RiderQuestion(
        riderId: j['riderId'] as String,
        riderName: j['riderName'] as String,
        nation: j['nation'] as String?,
      );
}

class AnswerResult {
  final bool correct;
  final String correctTeamName;

  AnswerResult({required this.correct, required this.correctTeamName});

  factory AnswerResult.fromJson(Map<String, dynamic> j) => AnswerResult(
        correct: j['correct'] as bool,
        correctTeamName: (j['correctTeamName'] as String?) ?? '',
      );
}

class LeaderRow {
  final String playerId;
  final String name;
  final int bestScore;
  final int total;
  final int plays;

  LeaderRow({
    required this.playerId,
    required this.name,
    required this.bestScore,
    required this.total,
    required this.plays,
  });

  factory LeaderRow.fromJson(Map<String, dynamic> j) => LeaderRow(
        playerId: j['playerId'] as String,
        name: (j['name'] as String?) ?? '',
        bestScore: (j['bestScore'] as num?)?.toInt() ?? 0,
        total: (j['total'] as num?)?.toInt() ?? sessionTotal,
        plays: (j['plays'] as num?)?.toInt() ?? 0,
      );
}

class QuizPage extends StatefulWidget {
  final String playerId;
  final String playerName;

  /// callback pour changer pseudo (met à jour Home + prefs)
  final Future<PlayerInfo> Function(String newName) onPlayerUpdated;

  const QuizPage({
    super.key,
    required this.playerId,
    required this.playerName,
    required this.onPlayerUpdated,
  });

  @override
  State<QuizPage> createState() => _QuizPageState();
}

class _QuizPageState extends State<QuizPage> {
  bool loading = true;
  String? error;

  List<Team> teams = [];
  RiderQuestion? current;
  String? selectedTeamId;

  late String playerId;
  late String playerName;

  int score = 0;
  int questionIndex = 0;

  @override
  void initState() {
    super.initState();
    playerId = widget.playerId;
    playerName = widget.playerName;
    _boot();
  }

  Future<void> _boot() async {
    setState(() {
      loading = true;
      error = null;
    });

    try {
      teams = await fetchTeams();
      await _newQuestion();
    } catch (e) {
      error = e.toString();
    } finally {
      setState(() => loading = false);
    }
  }

  Future<void> _newQuestion() async {
    selectedTeamId = null;
    current = await fetchQuestion();
    setState(() {});
  }

  Future<void> _submit() async {
    final q = current;
    final teamId = selectedTeamId;
    if (q == null || teamId == null) return;

    setState(() => loading = true);

    try {
      final res = await checkAnswer(riderId: q.riderId, teamId: teamId);

      if (res.correct) score += 1;

      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            res.correct ? '✅ Correct !' : '❌ Faux. Bonne équipe : ${res.correctTeamName}',
          ),
          duration: const Duration(milliseconds: 900),
        ),
      );

      questionIndex += 1;

      if (questionIndex >= sessionTotal) {
        await submitAttempt(playerId: playerId, score: score, total: sessionTotal);

        if (!mounted) return;
        await showDialog<void>(
          context: context,
          builder: (ctx) => AlertDialog(
            title: const Text("Session terminée"),
            content: Text("Ton score : $score / $sessionTotal"),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(ctx).pop(),
                child: const Text("OK"),
              ),
            ],
          ),
        );

        if (!mounted) return;
        Navigator.of(context).push(
          MaterialPageRoute(
            builder: (_) => LeaderboardPage(
              myPlayerId: playerId,
              total: sessionTotal,
            ),
          ),
        );

        score = 0;
        questionIndex = 0;
      }

      await _newQuestion();
    } catch (e) {
      setState(() => error = e.toString());
    } finally {
      setState(() => loading = false);
    }
  }

  Future<void> _changePseudo() async {
    final name = await askPseudoDialog(context, title: "Changer de pseudo");
    if (name == null) return;

    setState(() => loading = true);
    try {
      final updated = await widget.onPlayerUpdated(name);
      playerId = updated.playerId;
      playerName = updated.name;
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text("Pseudo mis à jour ✅")),
      );
    } finally {
      setState(() => loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final q = current;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Solo — Coureur → Équipe'),
        actions: [
          TextButton(
            onPressed: loading ? null : _changePseudo,
            child: Text(
              playerName,
              style: const TextStyle(color: Colors.white),
            ),
          ),
          IconButton(
            onPressed: loading
                ? null
                : () {
                    Navigator.of(context).push(
                      MaterialPageRoute(
                        builder: (_) => LeaderboardPage(
                          myPlayerId: playerId,
                          total: sessionTotal,
                        ),
                      ),
                    );
                  },
            icon: const Icon(Icons.leaderboard),
            tooltip: "Leaderboard",
          ),
        ],
      ),
      body: loading && q == null
          ? const Center(child: CircularProgressIndicator())
          : Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (error != null)
                    Container(
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: Theme.of(context).colorScheme.errorContainer,
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Text(error!),
                    ),
                  const SizedBox(height: 12),
                  _ScoreCard(score: score, current: questionIndex, total: sessionTotal),
                  const SizedBox(height: 16),
                  if (q != null) ...[
                    Text(q.riderName, style: Theme.of(context).textTheme.headlineMedium),
                    if ((q.nation ?? '').isNotEmpty) Text('Nation : ${q.nation}'),
                    const SizedBox(height: 16),
                    DropdownButtonFormField<String>(
                      value: selectedTeamId,
                      isExpanded: true,
                      decoration: const InputDecoration(
                        labelText: "Choisis l'équipe",
                        border: OutlineInputBorder(),
                      ),
                      items: teams.map((t) {
                        return DropdownMenuItem(
                          value: t.id,
                          child: Row(
                            children: [
                              // place pour l'image du maillot (jerseyUrl)
                              SizedBox(
                                width: 28,
                                height: 18,
                                child: t.jerseyUrl == null
                                    ? const DecoratedBox(
                                        decoration: BoxDecoration(
                                          color: Color(0xFFE9ECEF),
                                          borderRadius: BorderRadius.all(Radius.circular(4)),
                                        ),
                                      )
                                    : ClipRRect(
                                        borderRadius: BorderRadius.circular(4),
                                        child: Image.network(
                                          t.jerseyUrl!,
                                          fit: BoxFit.cover,
                                          errorBuilder: (_, __, ___) => const DecoratedBox(
                                            decoration: BoxDecoration(
                                              color: Color(0xFFE9ECEF),
                                              borderRadius: BorderRadius.all(Radius.circular(4)),
                                            ),
                                          ),
                                        ),
                                      ),
                              ),
                              const SizedBox(width: 10),
                              Expanded(child: Text('${t.name} (${t.categoryCode})')),
                            ],
                          ),
                        );
                      }).toList(),
                      onChanged: (v) => setState(() => selectedTeamId = v),
                    ),
                    const SizedBox(height: 12),
                    FilledButton(
                      onPressed: (loading || selectedTeamId == null) ? null : _submit,
                      child: loading
                          ? const SizedBox(
                              height: 18,
                              width: 18,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Text('Valider'),
                    ),
                    const SizedBox(height: 8),
                    TextButton(
                      onPressed: loading ? null : _newQuestion,
                      child: const Text('Passer (question suivante)'),
                    ),
                  ],
                ],
              ),
            ),
    );
  }
}

class _ScoreCard extends StatelessWidget {
  final int score;
  final int current;
  final int total;

  const _ScoreCard({
    required this.score,
    required this.current,
    required this.total,
  });

  @override
  Widget build(BuildContext context) {
    final progress = "${(current).clamp(0, total)}/$total";
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(12),
        color: Theme.of(context).colorScheme.surfaceContainerHighest,
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text('Score : $score', style: Theme.of(context).textTheme.titleMedium),
          Text('Progression : $progress', style: Theme.of(context).textTheme.titleMedium),
        ],
      ),
    );
  }
}

/// -------- LEADERBOARD PAGE --------

class LeaderboardPage extends StatefulWidget {
  final String myPlayerId;
  final int total;

  const LeaderboardPage({
    super.key,
    required this.myPlayerId,
    required this.total,
  });

  @override
  State<LeaderboardPage> createState() => _LeaderboardPageState();
}

class _LeaderboardPageState extends State<LeaderboardPage> {
  bool loading = true;
  String? error;
  List<LeaderRow> rows = [];

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      loading = true;
      error = null;
    });

    try {
      rows = await fetchLeaderboard(total: widget.total, limit: 50);
    } catch (e) {
      error = e.toString();
    } finally {
      setState(() => loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text("Leaderboard")),
      body: loading
          ? const Center(child: CircularProgressIndicator())
          : RefreshIndicator(
              onRefresh: _load,
              child: ListView(
                padding: const EdgeInsets.all(12),
                children: [
                  if (error != null)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 12),
                      child: Text(error!, style: const TextStyle(color: Colors.red)),
                    ),
                  Text("Meilleurs scores (sur ${widget.total})",
                      style: Theme.of(context).textTheme.titleLarge),
                  const SizedBox(height: 12),
                  for (int i = 0; i < rows.length; i++)
                    _LeaderTile(
                      rank: i + 1,
                      row: rows[i],
                      highlight: rows[i].playerId == widget.myPlayerId,
                    ),
                  if (rows.isEmpty) const Text("Aucun score enregistré pour l’instant."),
                ],
              ),
            ),
    );
  }
}

class _LeaderTile extends StatelessWidget {
  final int rank;
  final LeaderRow row;
  final bool highlight;

  const _LeaderTile({
    required this.rank,
    required this.row,
    required this.highlight,
  });

  @override
  Widget build(BuildContext context) {
    final bg = highlight
        ? Theme.of(context).colorScheme.primaryContainer
        : Theme.of(context).colorScheme.surfaceContainerHighest;

    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        children: [
          SizedBox(width: 34, child: Text("#$rank")),
          Expanded(
            child: Text(
              row.name,
              style: Theme.of(context).textTheme.titleMedium,
            ),
          ),
          Text("${row.bestScore}/${row.total}"),
          const SizedBox(width: 12),
          Text("(${row.plays}x)"),
        ],
      ),
    );
  }
}

/// -------- Shared dialogs / player init --------

Future<String?> askPseudoDialog(BuildContext context, {required String title}) async {
  final controller = TextEditingController();
  return showDialog<String>(
    context: context,
    barrierDismissible: false,
    builder: (ctx) {
      return AlertDialog(
        title: Text(title),
        content: TextField(
          controller: controller,
          autofocus: true,
          maxLength: 24,
          decoration: const InputDecoration(hintText: "Ex: Hbl25"),
        ),
        actions: [
          TextButton(
            onPressed: () {
              final v = controller.text.trim();
              if (v.length < 2) return;
              Navigator.of(ctx).pop(v);
            },
            child: const Text("OK"),
          ),
        ],
      );
    },
  );
}

Future<PlayerInfo> ensurePlayer(BuildContext context) async {
  final prefs = await SharedPreferences.getInstance();
  final savedId = prefs.getString('playerId');
  final savedName = prefs.getString('playerName');

  if (savedId != null && savedName != null && savedName.trim().isNotEmpty) {
    return PlayerInfo(playerId: savedId, name: savedName);
  }

  final name = await askPseudoDialog(context, title: "Ton pseudo");
  if (name == null) {
    throw Exception("Pseudo requis.");
  }

  final created = await createOrUpdatePlayer(name: name);

  await prefs.setString('playerId', created.playerId);
  await prefs.setString('playerName', created.name);

  return PlayerInfo(playerId: created.playerId, name: created.name);
}

/// -------- API calls --------

Future<List<Team>> fetchTeams() async {
  final res = await http.get(Uri.parse('$apiBase/teams'));
  if (res.statusCode != 200) {
    throw Exception('Failed to load teams: ${res.statusCode} ${res.body}');
  }
  final decoded = jsonDecode(res.body) as Map<String, dynamic>;
  final list = (decoded['teams'] as List).cast<Map<String, dynamic>>();
  return list.map(Team.fromJson).toList();
}

Future<RiderQuestion> fetchQuestion() async {
  final res = await http.get(Uri.parse('$apiBase/question'));
  if (res.statusCode != 200) {
    throw Exception('Failed to load question: ${res.statusCode} ${res.body}');
  }
  final decoded = jsonDecode(res.body) as Map<String, dynamic>;
  return RiderQuestion.fromJson(decoded['rider'] as Map<String, dynamic>);
}

Future<AnswerResult> checkAnswer({required String riderId, required String teamId}) async {
  final res = await http.post(
    Uri.parse('$apiBase/answer'),
    headers: {'Content-Type': 'application/json'},
    body: jsonEncode({'riderId': riderId, 'teamId': teamId}),
  );
  if (res.statusCode != 200) {
    throw Exception('Failed to check answer: ${res.statusCode} ${res.body}');
  }
  return AnswerResult.fromJson(jsonDecode(res.body) as Map<String, dynamic>);
}

class PlayerResponse {
  final String playerId;
  final String name;

  PlayerResponse({required this.playerId, required this.name});

  factory PlayerResponse.fromJson(Map<String, dynamic> j) => PlayerResponse(
        playerId: j['playerId'] as String,
        name: j['name'] as String,
      );
}

Future<PlayerResponse> createOrUpdatePlayer({String? playerId, required String name}) async {
  final res = await http.post(
    Uri.parse('$apiBase/player'),
    headers: {'Content-Type': 'application/json'},
    body: jsonEncode({
      if (playerId != null) 'playerId': playerId,
      'name': name,
    }),
  );

  if (res.statusCode != 200) {
    throw Exception('Failed to create/update player: ${res.statusCode} ${res.body}');
  }
  return PlayerResponse.fromJson(jsonDecode(res.body) as Map<String, dynamic>);
}

Future<void> submitAttempt({required String playerId, required int score, required int total}) async {
  final res = await http.post(
    Uri.parse('$apiBase/attempt'),
    headers: {'Content-Type': 'application/json'},
    body: jsonEncode({'playerId': playerId, 'score': score, 'total': total}),
  );
  if (res.statusCode != 200) {
    throw Exception('Failed to submit attempt: ${res.statusCode} ${res.body}');
  }
}

Future<List<LeaderRow>> fetchLeaderboard({required int total, int limit = 50}) async {
  final res = await http.get(Uri.parse('$apiBase/leaderboard?total=$total&limit=$limit'));
  if (res.statusCode != 200) {
    throw Exception('Failed to load leaderboard: ${res.statusCode} ${res.body}');
  }
  final decoded = jsonDecode(res.body) as Map<String, dynamic>;
  final list = (decoded['leaderboard'] as List).cast<Map<String, dynamic>>();
  return list.map(LeaderRow.fromJson).toList();
}
