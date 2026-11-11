import Foundation

/// Transfert en cours, pour l'interface : progression en flux, annulation, résultat final.
///
/// Créé par `SFTPClient.startDownload` / `startUpload`. Le transfert démarre aussitôt. Annuler (`cancel()`) ou annuler
/// la tâche qui attend `outcome` interrompt le transfert : `outcome` lève alors `SFTPError.cancelled` (fichier partiel
/// laissé en place, la reprise vérifiée pourra le réutiliser). Le flux `progress` ne retient que le dernier instantané
/// (un consommateur lent ne ralentit jamais le transfert) et se termine à la fin du transfert, quel qu'en soit le résultat.
public final class SFTPTransferTask: Sendable {
    public let progress: AsyncStream<SFTPTransferSnapshot>
    private let task: Task<SFTPTransferOutcome, any Error>

    init(progress: AsyncStream<SFTPTransferSnapshot>, task: Task<SFTPTransferOutcome, any Error>) {
        self.progress = progress
        self.task = task
    }

    /// Demande l'arrêt ; retour immédiat, la fin effective se constate via `outcome`.
    public func cancel() { task.cancel() }

    /// Attend la fin du transfert. Ne lève que des `SFTPError`.
    public var outcome: SFTPTransferOutcome {
        get async throws {
            do { return try await task.value } catch let e as SFTPError { throw e }
            catch { throw SFTPError.localIO(String(describing: error)) }
        }
    }
}

extension SFTPClient {
    /// Lance un téléchargement suivi. `resume` : reprise vérifiée à partir du fichier local partiel (sinon, départ de zéro).
    public nonisolated func startDownload(remotePath: some SFTPPathRepresentable, to localURL: URL, resume: Bool = true,
                                          verification: SFTPResumeVerification = .default) -> SFTPTransferTask {
        let path = remotePath.sftpBytes
        return makeTask { observer in
            do {
                if resume {
                    return try await self.downloadResuming(remotePath: path, to: localURL, verification: verification, observer: observer)
                }
                let n = try await self.runDownload(path: path, to: localURL, resumeFrom: 0, progress: nil, observer: observer)
                return SFTPTransferOutcome(totalBytes: n, resumedFrom: 0, restartReason: nil)
            } catch is CancellationError {
                throw SFTPError.cancelled(partialLocalFile: localURL, bytesTransferred: 0)
            }
        }
    }

    /// Lance un envoi suivi. `resume` : reprise vérifiée à partir du fichier distant partiel (sinon, départ de zéro).
    public nonisolated func startUpload(localURL: URL, to remotePath: some SFTPPathRepresentable, resume: Bool = true,
                                        verification: SFTPResumeVerification = .default) -> SFTPTransferTask {
        let path = remotePath.sftpBytes
        return makeTask { observer in
            do {
                if resume {
                    return try await self.uploadResuming(localURL: localURL, to: path, verification: verification, observer: observer)
                }
                let n = try await self.runUpload(localURL: localURL, path: path, resumeFrom: 0, progress: nil, observer: observer)
                return SFTPTransferOutcome(totalBytes: n, resumedFrom: 0, restartReason: nil)
            } catch is CancellationError {
                throw SFTPError.cancelled(partialLocalFile: nil, bytesTransferred: 0)
            }
        }
    }

    private nonisolated func makeTask(_ body: @escaping @Sendable (@escaping @Sendable (SFTPTransferSnapshot) -> Void) async throws -> SFTPTransferOutcome) -> SFTPTransferTask {
        let (stream, continuation) = AsyncStream<SFTPTransferSnapshot>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let task = Task<SFTPTransferOutcome, any Error> {
            defer { continuation.finish() }
            return try await body { continuation.yield($0) }
        }
        return SFTPTransferTask(progress: stream, task: task)
    }
}
