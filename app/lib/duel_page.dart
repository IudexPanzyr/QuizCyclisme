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

      await poll();
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

  List<Map<String, dynamic>> _players() {
    return (stateJson?['players'] as List?)?.cast<dynamic>().map((e) => (e as Map).cast<String, dynamic>()).toList() ?? [];
  }

  List<Map<String, dynamic>> _scores() {
    return (stateJson?['scores'] as List?)?.cast<dynamic>().map((e) => (e as Map).cast<String, dynamic>()).toList() ?? [];
  }

  @override
  Widget build(BuildContext context) {
    final duel = stateJson?['duel'] as Map<String, dynamic>?;
    final status = (duel?['status'] as String?) ?? (code == null ? 'none' : 'lobby');
    final total = (duel?['total'] as num?)?.toInt() ?? 30;
    final currentRound = (duel?['currentRound'] as num?)?.toInt() ?? 1;

    final players = _players();
    final scores = _scores();
    final meId = widget.playerId;

    bool isHost = false;
    for (final p in players) {
      if (p['playerId'] == meId && (p['side'] as num?)?.toInt() == 1) {
        isHost = true;
      }
    }

    int scoreOf(String playerId) {
      final row = scores.firstWhere(
        (s) => (s['playerId'] as String?) == playerId,
        orElse: () => const {},
      );
      return (row['score'] as num?)?.toInt() ?? 0;
    }

    Widget scoreboard() {
      if (players.isEmpty) return const SizedBox.shrink();
      final p1 = players.firstWhere((p) => (p['side'] as num?)?.toInt() == 1, orElse: () => const {});
      final p2 = players.firstWhere((p) => (p['side'] as num?)?.toInt() == 2, orElse: () => const {});
      final p1Id = (p1['playerId'] as String?) ?? '';
      final p2Id = (p2['playerId'] as String?) ?? '';
      final p1Name = (p1['name'] as String?) ?? 'Hôte';
      final p2Name = (p2['name'] as String?) ?? (players.length < 2 ? 'En attente…' : 'Joueur 2');

      return Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(12),
          color: Theme.of(context).colorScheme.surfaceContainerHighest,
        ),
        child: Row(
          children: [
            Expanded(child: Text(p1Name, style: Theme.of(context).textTheme.titleMedium)),
            Text("${scoreOf(p1Id)}", style: Theme.of(context).textTheme.titleLarge),
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 10),
              child: Text("—"),
            ),
            Text("${p2Id.isEmpty ? 0 : scoreOf(p2Id)}", style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                p2Name,
                textAlign: TextAlign.end,
                style: Theme.of(context).textTheme.titleMedium,
              ),
            ),
          ],
        ),
      );
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

              scoreboard(),
              const SizedBox(height: 12),

              ...players.map((p) {
                final name = (p['name'] as String?) ?? '???';
                final side = (p['side'] as num?)?.toInt() ?? 0;
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

class DuelTeam {
  final String id;
  final String name;
  final String categoryCode;
  final String? jerseyUrl;

  DuelTeam({
    required this.id,
    required this.name,
    required this.categoryCode,
    required this.jerseyUrl,
  });

  factory DuelTeam.fromJson(Map<String, dynamic> j) => DuelTeam(
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

  List<DuelTeam> teams = [];
  Map<String, dynamic>? stateJson;
  Map<String, dynamic>? questionJson;

  String? selectedTeamId;

  Timer? timer;

  // ---- TIMER ROUND 15s ----
  Timer? roundTimer;
  int timeLeft = 15;
  int? lastRoundNo;
  bool sendingTimeout = false;

  @override
  void initState() {
    super.initState();
    _boot();
  }

  @override
  void dispose() {
    timer?.cancel();
    roundTimer?.cancel();
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

  void _startRoundTimer() {
    roundTimer?.cancel();
    timeLeft = 15;
    sendingTimeout = false;

    roundTimer = Timer.periodic(const Duration(seconds: 1), (t) async {
      if (!mounted) return;

      if (timeLeft <= 1) {
        t.cancel();
        await _sendTimeoutIfNeeded();
      } else {
        setState(() => timeLeft -= 1);
      }
    });

    if (mounted) setState(() {});
  }

  Future<void> _sendTimeoutIfNeeded() async {
    if (sendingTimeout) return;

    final duel = stateJson?['duel'] as Map<String, dynamic>?;
    final status = (duel?['status'] as String?) ?? '';
    final meAnswered = ((stateJson?['me'] as Map?)?['answeredThisRound'] == true);

    if (status != 'active' || meAnswered) return;

    sendingTimeout = true;

    try {
      await http.post(
        Uri.parse('${widget.apiBase}/duel/${widget.code}/answer'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({'playerId': widget.playerId, 'teamId': '__TIMEOUT__'}),
      );

      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text("⏱️ Temps écoulé (réponse vide)"),
          duration: Duration(milliseconds: 900),
        ),
      );

      selectedTeamId = null;
      await poll();
    } catch (_) {
      // ignore
    }
  }

  List<Map<String, dynamic>> _players() {
    return (stateJson?['players'] as List?)?.cast<dynamic>().map((e) => (e as Map).cast<String, dynamic>()).toList() ?? [];
  }

  List<Map<String, dynamic>> _scores() {
    return (stateJson?['scores'] as List?)?.cast<dynamic>().map((e) => (e as Map).cast<String, dynamic>()).toList() ?? [];
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

      // ---- gestion du timer par round ----
      final meAnswered = ((stateJson?['me'] as Map?)?['answeredThisRound'] == true);
      final round = (questionJson?['round'] as Map?)?.cast<String, dynamic>();
      final roundNo = (round?['roundNo'] as num?)?.toInt();

      if (status == 'active' && roundNo != null) {
        if (lastRoundNo != roundNo) {
          lastRoundNo = roundNo;
          if (!meAnswered) {
            _startRoundTimer();
          } else {
            roundTimer?.cancel();
          }
        } else {
          if (meAnswered) roundTimer?.cancel();
        }
      } else {
        roundTimer?.cancel();
      }

      if (mounted) setState(() {});
    } catch (_) {
      // ignore
    }
  }

  Future<List<DuelTeam>> _fetchTeams() async {
    final res = await http.get(Uri.parse('${widget.apiBase}/teams'));
    if (res.statusCode != 200) throw Exception("Teams: ${res.statusCode} ${res.body}");
    final decoded = jsonDecode(res.body) as Map<String, dynamic>;
    final list = (decoded['teams'] as List).cast<Map<String, dynamic>>();
    return list.map(DuelTeam.fromJson).toList();
  }

  Future<void> _submitAnswer() async {
    final teamId = selectedTeamId;
    if (teamId == null) return;

    roundTimer?.cancel();

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

      selectedTeamId = null;
      await poll();
    } catch (e) {
      setState(() => error = e.toString());
      _startRoundTimer();
    } finally {
      if (mounted) setState(() => loading = false);
    }
  }

  Widget _scoreboard(BuildContext context) {
    final players = _players();
    final scores = _scores();

    int scoreOf(String playerId) {
      final row = scores.firstWhere(
        (s) => (s['playerId'] as String?) == playerId,
        orElse: () => const {},
      );
      return (row['score'] as num?)?.toInt() ?? 0;
    }

    if (players.isEmpty) return const SizedBox.shrink();

    final p1 = players.firstWhere((p) => (p['side'] as num?)?.toInt() == 1, orElse: () => const {});
    final p2 = players.firstWhere((p) => (p['side'] as num?)?.toInt() == 2, orElse: () => const {});

    final p1Id = (p1['playerId'] as String?) ?? '';
    final p2Id = (p2['playerId'] as String?) ?? '';

    final p1Name = (p1['name'] as String?) ?? 'P1';
    final p2Name = (p2['name'] as String?) ?? 'P2';

    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(12),
        color: Theme.of(context).colorScheme.surfaceContainerHighest,
      ),
      child: Row(
        children: [
          Expanded(child: Text(p1Name, style: Theme.of(context).textTheme.titleMedium)),
          Text("${scoreOf(p1Id)}", style: Theme.of(context).textTheme.titleLarge),
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 10),
            child: Text("—"),
          ),
          Text("${scoreOf(p2Id)}", style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              p2Name,
              textAlign: TextAlign.end,
              style: Theme.of(context).textTheme.titleMedium,
            ),
          ),
        ],
      ),
    );
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
                  const SizedBox(height: 10),

                  _scoreboard(context),
                  const SizedBox(height: 10),

                  if (status == 'active') Text("⏱️ Temps restant : $timeLeft s"),
                  const SizedBox(height: 16),

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
