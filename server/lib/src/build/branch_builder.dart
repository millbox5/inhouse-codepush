import 'dart:io';

/// Dashboard "pick a branch -> build -> push a patch" runner.
///
/// Delegates the actual build to [scriptPath] (tooling/push-branch.sh), which
/// resets the configured git worktree to `origin/<branch>` and runs the build.
/// Lists remote branches from [worktreeDir] for the picker.
class BranchBuilder {
  BranchBuilder({required this.scriptPath, required this.worktreeDir});

  final String scriptPath;
  final String worktreeDir;

  /// Fresh list of remote branch names (without the `origin/` prefix, and
  /// without the symbolic `origin/HEAD`), straight from the worktree's remotes.
  /// Empty when branch tooling isn't configured or the worktree is unreachable.
  Future<List<String>> branches() async {
    if (worktreeDir.isEmpty) return const [];

    final result = await Process.run(
      'git',
      ['-C', worktreeDir, 'for-each-ref', 'refs/remotes/origin/'],
      stdoutEncoding: const SystemEncoding(),
    );

    if (result.exitCode != 0) return const [];

    return (result.stdout.toString().split('\n'))
        .map((line) => line.split('\t').last.trim())
        .where((ref) => ref.isNotEmpty && ref != 'refs/remotes/origin/HEAD')
        .map((ref) => ref.replaceFirst('refs/remotes/origin/', ''))
        .toList();
  }
}