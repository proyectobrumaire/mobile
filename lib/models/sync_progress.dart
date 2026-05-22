class SyncProgress {
  final String message;
  final bool isError;
  final bool isWarning;
  const SyncProgress(this.message, {this.isError = false, this.isWarning = false});
}
