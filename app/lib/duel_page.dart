import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

class DuelPage extends StatefulWidget {
  final String apiBase;
  final String playerId;
  final String playerName;

  const DuelPage({
    super.key,
    required this.apiBase,
    required this.playerId,
    required this.playerName,
  });

  @override
  State<DuelPage> createState() => _DuelPageState();
}

class _DuelPageState extends State<DuelPage> {
  final codeCtrl = TextEditingController();
  String? code;

  Map<String, dynamic>? stateJson;
  String? error;
  bool busy = false;

  Timer? timer;
  bool openedMatch = false;

  @override
  void dispose() {
    timer?.cancel();
    codeCtrl.dispose();
    super.dispose();
  }

  void _startPolling() {
    timer?.cancel();
    timer = Timer.periodic(const Duration(milliseconds: 900), (_) => poll());
    poll();
  }

  Future<void> createLobby() async {
    setState(() {
      busy = true;
      error = null;
      openedMatch = false;
    });

    try {
      final res = await http.post(
        Uri.parse('${widget.apiBase}/duel/create'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({'playerId': widget.playerId, 'total': 30}),
      );

      if (res.statusCode != 200) {
        throw Exception('Create failed: ${res.statusCode} ${res.body}');
      }

      final j = jsonDecode(res.body) as Map<String, dynamic>;
      code = (j['code'] as String).toUpperCase();
      codeCtrl.text = code!;

      _startPolling();
    } catch (e) {
      setState(() => error = e.toString());
    } finally {
      setState(() => busy = false);
    }
  }

  Future<void> joinLobby() async {
    final c = codeCtrl.text.trim().toUpperCase();
    if (c.isEmpty) return;

    setState(() {
      busy = true;
      error = null;
      openedMatch = false;
    });

    try {
      final res = await http.post(
        Uri.parse('${widget.apiBase}/duel/join'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({'playerId': widget.playerId, 'code': c}),
      );

      if (res.statusCode != 200) {
        throw Exception('Join failed: ${res.statusCode} ${res.body}');
      }

      code = c;
      _startPolling();
    } catch (e) {
      setState(() => error = e.toString());
    } finally {
      setState(() => busy = false);
    }
  }

  Future<void> startMatch() async {
    final c = code;
    if (c == null) return;

    setState(() {
      busy = true;
      error = null;
    });

    try {
      final res = await http.post(
        Uri.parse('${widget.apiBase}/duel/start'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({'playerId': widget.playerId, 'code': c}),
      );

      if (res.statusCode != 200) {
        throw Exception('Start failed: ${res.statusCode} ${res.body}');
      }

      await poll(); // refresh state immediately
    } catch (e) {
      setState(() => error = e.toString());
    } finally {
      setState(() => busy = false);
    }
  }

  Future<void> poll() async {
    final c = code;
    if (c == null) return;

    try {
      final sRes = await http.get(
        Uri.parse('${widget.apiBase}/duel/$c/state?playerId=${Uri.encodeComponent(widget.playerId)}'),
      );

      if (sRes.statusCode != 200) return;

      stateJson = jsonDecode(sRes.body) as Map<String, dynamic>;
      if (!mounted) return;
      setState(() {});

      final duel = stateJson?['duel'] as Map<String, dynamic>?;
      final status = (duel?['status'] as String?) ?? 'lobby';

      // Auto-open match screen when active
      if (status == 'active' && !openedMatch) {
        openedMatch = true;
        Navigator.of(context).push(
          MaterialPageRoute(
            builder: (_) => DuelMatchPage(
              apiBase: widget.apiBase,
              playerId: widget.playerId,
              playerName: widget.playerName,
              code: c,
            ),
          ),
        );
      }
    } catch (_) {
      // ignore
    }
  }

  @override
  Widget build(BuildContext context) {
    final duel = stateJson?['duel'] as Map<String, dynamic>?;
    final status = (duel?['status'] as String?) ?? (code == null ? 'none' : 'lobby');
    final total = (duel?['total'] as num?)?.toInt() ?? 30;
    final currentRound = (duel?['currentRound'] as num?)?.toInt() ?? 1;

    final players = (stateJson?['players'] as List?)?.cast<dynamic>() ?? const [];
    final meId = widget.playerId;

    bool isHost = false;
    for (final p in players) {
      final m = (p as Map).cast<String, dynamic>();
      if (m['playerId'] == meId && (m['side'] as num?)?.toInt() == 1) {
        isHost = true;
      }
    }

    return Scaffold(
      appBar: AppBar(title: const Text("Duels")),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (error != null) ...[
              Text(error!, style: const TextStyle(color: Colors.red)),
              const SizedBox(height: 12),
            ],

            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: codeCtrl,
                    decoration: const InputDecoration(
                      labelText: "Code duel",
                      border: OutlineInputBorder(),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                FilledButton(
                  onPressed: busy ? null : joinLobby,
                  child: const Text("Rejoindre"),
                ),
              ],
            ),

            const SizedBox(height: 10),

            FilledButton(
              onPressed: busy ? null : createLobby,
              child: const Text("Créer un lobby"),
            ),

            const SizedBox(height: 18),

            if (code != null) ...[
              Text("Code: $code", style: Theme.of(context).textTheme.titleLarge),
              const SizedBox(height: 6),
              Text("Status: $status"),
              const SizedBox(height: 6),
              Text("Round: $currentRound / $total"),
              const SizedBox(height: 12),

              ...players.map((p) {
                final m = (p as Map).cast<String, dynamic>();
                final name = (m['name'] as String?) ?? '???';
                final side = (m['side'] as num?)?.toInt() ?? 0;
                return Text("${side == 1 ? 'Hôte' : 'Joueur'}: $name");
              }),

              const SizedBox(height: 14),

              if (status == 'lobby') ...[
                Text(players.length < 2 ? "En attente d’un 2e joueur…" : "Deux joueurs connectés ✅"),
                const SizedBox(height: 10),
                if (isHost)
                  FilledButton.icon(
                    onPressed: (busy || players.length < 2) ? null : startMatch,
                    icon: const Icon(Icons.play_arrow),
                    label: const Padding(
                      padding: EdgeInsets.symmetric(vertical: 10),
                      child: Text("Lancer la partie"),
                    ),
                  )
                else
                  const Text("En attente que l’hôte lance la partie…"),
              ],

              if (status == 'active')
                const Text("Partie lancée ✅ (ouverture de l’écran de jeu…)"),
            ],
          ],
        ),
      ),
    );
  }
}

/// ---------------- MATCH SCREEN (play) ----------------

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

class DuelMatchPage extends StatefulWidget {
  final String apiBase;
  final String playerId;
  final String playerName;
  final String code;

  const DuelMatchPage({
    super.key,
    required this.apiBase,
    required this.playerId,
    required this.playerName,
    required this.code,
  });

  @override
  State<DuelMatchPage> createState() => _DuelMatchPageState();
}

class _DuelMatchPageState extends State<DuelMatchPage> {
  bool loading = true;
  String? error;

  List<Team> teams = [];
  Map<String, dynamic>? stateJson;
  Map<String, dynamic>? questionJson;

  String? selectedTeamId;
  Timer? timer;

  @override
  void initState() {
    super.initState();
    _boot();
  }

  @override
  void dispose() {
    timer?.cancel();
    super.dispose();
  }

  Future<void> _boot() async {
    setState(() {
      loading = true;
      error = null;
    });

    try {
      teams = await _fetchTeams();
      _startPolling();
    } catch (e) {
      setState(() => error = e.toString());
    } finally {
      if (mounted) setState(() => loading = false);
    }
  }

  void _startPolling() {
    timer?.cancel();
    timer = Timer.periodic(const Duration(milliseconds: 900), (_) => poll());
    poll();
  }

  Future<void> poll() async {
    try {
      final sRes = await http.get(Uri.parse(
        '${widget.apiBase}/duel/${widget.code}/state?playerId=${Uri.encodeComponent(widget.playerId)}',
      ));
      if (sRes.statusCode != 200) return;

      stateJson = jsonDecode(sRes.body) as Map<String, dynamic>;

      final duel = stateJson?['duel'] as Map<String, dynamic>?;
      final status = (duel?['status'] as String?) ?? 'lobby';

      if (status == 'active') {
        final qRes = await http.get(Uri.parse(
          '${widget.apiBase}/duel/${widget.code}/question?playerId=${Uri.encodeComponent(widget.playerId)}',
        ));
        if (qRes.statusCode == 200) {
          questionJson = jsonDecode(qRes.body) as Map<String, dynamic>;
        }
      }

      if (mounted) setState(() {});
    } catch (_) {
      // ignore
    }
  }

  Future<List<Team>> _fetchTeams() async {
    final res = await http.get(Uri.parse('${widget.apiBase}/teams'));
    if (res.statusCode != 200) throw Exception("Teams: ${res.statusCode} ${res.body}");
    final decoded = jsonDecode(res.body) as Map<String, dynamic>;
    final list = (decoded['teams'] as List).cast<Map<String, dynamic>>();
    return list.map(Team.fromJson).toList();
  }

  Future<void> _submitAnswer() async {
    final teamId = selectedTeamId;
    if (teamId == null) return;

    setState(() {
      loading = true;
      error = null;
    });

    try {
      final res = await http.post(
        Uri.parse('${widget.apiBase}/duel/${widget.code}/answer'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({'playerId': widget.playerId, 'teamId': teamId}),
      );

      if (res.statusCode != 200) {
        throw Exception("Answer: ${res.statusCode} ${res.body}");
      }

      final j = jsonDecode(res.body) as Map<String, dynamic>;
      final correct = j['correct'] == true;
      final correctName = (j['correctTeamName'] as String?) ?? '';

      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(correct ? "✅ Correct !" : "❌ Faux. Bonne équipe : $correctName"),
          duration: const Duration(milliseconds: 900),
        ),
      );

      selectedTeamId = null; // reset pour le prochain round
      await poll();
    } catch (e) {
      setState(() => error = e.toString());
    } finally {
      if (mounted) setState(() => loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final duel = stateJson?['duel'] as Map<String, dynamic>?;
    final status = (duel?['status'] as String?) ?? '...';
    final total = (duel?['total'] as num?)?.toInt() ?? 30;
    final currentRound = (duel?['currentRound'] as num?)?.toInt() ?? 1;
    final meAnswered = ((stateJson?['me'] as Map?)?['answeredThisRound'] == true);

    final round = (questionJson?['round'] as Map?)?.cast<String, dynamic>();
    final riderName = round?['riderName'] as String?;
    final nation = round?['nation'] as String?;

    return Scaffold(
      appBar: AppBar(title: Text("Match ${widget.code}")),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: loading && stateJson == null
            ? const Center(child: CircularProgressIndicator())
            : Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (error != null) ...[
                    Text(error!, style: const TextStyle(color: Colors.red)),
                    const SizedBox(height: 12),
                  ],
                  Text("Status: $status"),
                  const SizedBox(height: 6),
                  Text("Round: $currentRound / $total"),
                  const SizedBox(height: 16),

                  // ---- ICI : affichage selon status ----
                  if (status == 'lobby') ...[
                    const Text("En attente que la partie démarre…"),
                  ] else if (status == 'finished') ...[
                    _FinishedPanel(stateJson: stateJson, myPlayerId: widget.playerId),
                  ] else if (status == 'active' && riderName != null) ...[
                    Text(riderName, style: Theme.of(context).textTheme.headlineSmall),
                    if ((nation ?? '').isNotEmpty) Text("Nation: $nation"),
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
                      onChanged: meAnswered ? null : (v) => setState(() => selectedTeamId = v),
                    ),
                    const SizedBox(height: 12),

                    FilledButton(
                      onPressed: (loading || meAnswered || selectedTeamId == null) ? null : _submitAnswer,
                      child: Text(meAnswered ? "Réponse envoyée ✅" : "Valider"),
                    ),
                  ] else ...[
                    const Text("Chargement de la question…"),
                  ],
                ],
              ),
      ),
    );
  }
}

class _FinishedPanel extends StatelessWidget {
  final Map<String, dynamic>? stateJson;
  final String myPlayerId;

  const _FinishedPanel({required this.stateJson, required this.myPlayerId});

  @override
  Widget build(BuildContext context) {
    final result = (stateJson?['result'] as Map?)?.cast<String, dynamic>();
    if (result == null) {
      return const Text("Match terminé ✅ (résultat indisponible)");
    }

    final p1 = (result['p1'] as Map?)?.cast<String, dynamic>();
    final p2 = (result['p2'] as Map?)?.cast<String, dynamic>();
    final winner = (result['winnerPlayerId'] as String?);

    String line(Map<String, dynamic>? p) {
      final name = (p?['name'] as String?) ?? '???';
      final score = (p?['score'] as num?)?.toInt() ?? 0;
      return "$name — $score";
    }

    String verdict() {
      if (winner == null) return "🤝 Égalité !";
      if (winner == myPlayerId) return "🏆 Tu as gagné !";
      return "😅 Tu as perdu…";
    }

    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(12),
        color: Theme.of(context).colorScheme.surfaceContainerHighest,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text("Résultat final", style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: 10),
          Text(line(p1)),
          Text(line(p2)),
          const SizedBox(height: 12),
          Text(verdict(), style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 8),
          const Text("Le score est enregistré ✅"),
        ],
      ),
    );
  }
}