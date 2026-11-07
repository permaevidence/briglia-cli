#!/usr/bin/env python3
"""Deliberate breaks for Sign in with ChatGPT, stages A, B and C (SIWC plan v3.2 §8).

Same method as keyless_web_break_test.py: copy the tree to a scratch
directory, build once (positive control: `__siwc-selftest` passes), then
apply one mutation at a time, rebuild incrementally and require the NAMED
check (a label prefix of `__siwc-selftest`) to be reported failed (✖), not
just a non-zero exit. The repository is never modified; the selftest runs
offline with temporary XDG roots.

Usage: python3 scripts/siwc_break_test.py [--keep-build DIR] [--only S1,S2] [--check-anchors]
"""
import argparse
import os
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
LINUX_JOBS = ["-j", "2"] if sys.platform.startswith("linux") else []
W = "TelegramConcierge/Services/SIWC/"
S = "TelegramConcierge/Services/"
SS = "TelegramConcierge/Services/Settings/"

# (label, failing check label prefix, file, old, new)
BREAKS = [
    ("S1 the binding leaves out the refresh token", "binding: refresh token changed alone", W + "SIWCStore.swift",
     "        bound.bindingVersion = bindingVersion\n        return mac(", "        bound.bindingVersion = bindingVersion\n        bound.tokens?.refresh = \"\"\n        return mac("),
    ("S2 identity is not checked against the registration", "binding: a registration whose sub changed", W + "SIWCStore.swift",
     "            guard identity.subKey == Self.mac(key, \"siwc-sub\", Data(registration.sub.utf8)) else { return \"identity disagrees with the registration\" }",
     "            _ = identity"),
    ("S3 an unbound record is refreshed", "binding: access token changed alone", W + "SIWCStore+Refresh.swift",
     "            case .signInRequired: throw SIWCError(.signInRequired, SIWCError.signInMessage)\n            }\n            guard let key, var old",
     "            case .signInRequired: break\n            }\n            guard let key, var old"),
    ("S4 the integrity key is re-created while records exist", "binding: the key is never re-created", W + "SIWCStore+Login.swift",
     "                    guard !hasRecords else {", "                    guard !hasRecords || true else {"),
    ("S5 a new host ID is minted while users exist", "host: a missing host file with users is a refusal", W + "SIWCHost.swift",
     "                guard let users, users.isEmpty, reservations.reservations.isEmpty else {", "                guard true else {"),
    ("S6 publication ignores an expired reservation", "host: a callback after the reservation expired is refused", W + "SIWCHost.swift",
     "              reservation.expiresAt > now, reservation.hostFingerprint == hostFingerprint,",
     "              reservation.expiresAt > now - 100000, reservation.hostFingerprint == hostFingerprint,"),
    ("S7 the host is removed under a live reservation", "host: removal refused while a live reservation exists", W + "SIWCHost.swift",
     "            if reservations.reservations.contains(where: { isLive($0, now: now) }) { return .keptInUse }", "            _ = reservations"),
    ("S8 a dead owner's reservation is kept", "host: a dead owner's reservation is removed", W + "SIWCHost.swift",
     "        if let lease = reservation.ownerLease, ProfileFileLock.probe(URL(fileURLWithPath: lease)) == .dead { return false }", "        _ = reservation.ownerLease"),
    ("S9 saving a login moves the active pointer", "store: saving never moves the active pointer", W + "SIWCStore+Login.swift",
     "                let inUse = inUseByCaller || registrations.active == result.clientId\n",
     "                if registrations.active == nil { registrations.active = result.clientId; try writeRegistrations(registrations) }\n                let inUse = inUseByCaller || registrations.active == result.clientId\n"),
    ("S10 an in-use re-sign-in replaces the tokens directly", "login: in-use re-sign-in is staged", W + "SIWCStore+Login.swift",
     "                let inUse = inUseByCaller || registrations.active == result.clientId\n", "                let inUse = inUseByCaller\n"),
    ("S11 activation skips its expectation", "login: an activation prepared from an older state is refused", W + "SIWCStore+Login.swift",
     "                guard record.generation == expect.generation else {", "                guard true else {"),
    ("S12 the tombstone keeps the tokens", "signout: tokens cleared, generation changed", W + "SIWCStore+Login.swift",
     "            record.tokens = nil; record.identity = nil; record.staged = nil\n            record.requiresLogin = nil;",
     "            record.staged = nil\n            record.requiresLogin = nil;"),
    ("S13 retirement drops the effect mark", "retire: each record carries the same effect mark", W + "SIWCStore+Login.swift",
     "                record.lastEffect = effect\n                record.savedAt = nowSeconds\n", "                record.savedAt = nowSeconds\n"),
    ("S14 refresh ignores earliest_refresh_at", "refresh: never before earliest_refresh_at", W + "SIWCStore+Refresh.swift",
     "            let earliestOK = (old.earliestRefreshAt ?? 0) <= now", "            let earliestOK = true"),
    ("S15 a checkpoint is promoted without its MAC", "recovery: a checkpoint with a wrong MAC is discarded", W + "SIWCStore+Refresh.swift",
     "                if macOK, pending.generation == generation,", "                if macOK || true, pending.generation == generation,"),
    ("S16 the one recovery is not enforced", "recovery: exactly two sends in total", W + "SIWCStore+Refresh.swift",
     "            if let recovery = record.refreshRecovery, recovery.generation == generation, recovery.tokenFingerprint == fingerprint {",
     "            if let recovery = record.refreshRecovery, recovery.generation == \"never\", recovery.tokenFingerprint == fingerprint {"),
    ("S17 a refresh is sent without a durable op record", "recovery: zero sends without a durable op record", W + "SIWCStore+Refresh.swift",
     "                                             startedAt: nowSeconds, state: \"sending\")\n            try save()",
     "                                             startedAt: nowSeconds, state: \"sending\")\n            try? save()"),
    ("S18 a terminal refresh error does not require sign-in", "refresh: terminal → tokens cleared", W + "SIWCStore+Refresh.swift",
     "                        record.requiresLogin = true\n                        record.cleanup", "                        record.cleanup"),
    ("S19 a refresh naming another account is activated", "refresh: a refresh naming another account is never activated", W + "SIWCStore+Refresh.swift",
     "                identity.subKey == registrationSubKey && identity.subKey == oldIdentity.subKey\n                    && tokens.valid",
     "                tokens.valid"),
    ("S20 the ID-token signature is not verified", "jwt: a signature by another key under this kid is refused", W + "SIWCJWT.swift",
     "        guard verifyRS256(key: key, message: signed, signature: signature) else", "        guard verifyRS256(key: key, message: signed, signature: signature) || true else"),
    ("S21 the nonce is not checked", "jwt: a wrong nonce is refused", W + "SIWCJWT.swift",
     "        if let nonce {\n", "        if let nonce, nonce.isEmpty {\n"),
    ("S22 azp is not checked", "jwt: azp naming another client is refused", W + "SIWCJWT.swift",
     "        if let azp = claims[\"azp\"], azp as? String != clientId { throw Failure(\"azp mismatch\") }", "        _ = 0"),
    ("S23 short RSA keys are accepted", "jwt: keys under 2048 bits refused", W + "SIWCJWT.swift",
     "        guard bits >= 2048, n.count <= 1024 else", "        guard bits >= 1024, n.count <= 1024 else"),
    ("S24 a leading zero JWK integer is accepted", "jwk: a leading zero octet in n is refused", W + "SIWCJWT.swift",
     "            guard first != 0 else {", "            guard first != 0 || true else {"),
    ("S25 the pasted path is case-folded", "paste: path case kept (/AUTH)", W + "CallbackPaste.swift",
     "        guard checked == SIWCEndpoint.callbackPath else", "        guard checked.lowercased() == SIWCEndpoint.callbackPath else"),
    ("S26 + is form-decoded to a space", "paste: + stays +", W + "CallbackPaste.swift",
     "            } else { bytes.append(byte) }", "            } else { bytes.append(byte == 43 ? 32 : byte) }"),
    ("S27 state is compared case-insensitively", "paste: state never case-folded", W + "CallbackPaste.swift",
     "guard let state = q[\"state\"], SIWCJWT.constantTimeEqual(state, expectation.state) else",
     "guard let state = q[\"state\"], SIWCJWT.constantTimeEqual(state.lowercased(), expectation.state.lowercased()) else"),
    ("S28 an unknown error code is kept (and echoed)", "paste: an unknown error code is dropped and never echoed", W + "CallbackPaste.swift",
     "            return .error(recognized: recognizedErrors.contains(error) ? error : nil)", "            return .error(recognized: error)"),
    ("S29 the listener accepts a localhost Host", "listener: localhost Host header refused", W + "SIWCSignIn.swift",
     "              request.headers[\"host\"] == \"127.0.0.1:\\(expectation.port)\" else", "              request.headers[\"host\"]?.hasSuffix(\":\\(expectation.port)\") == true else"),
    ("S30 a later system note may become the prompt", "body: input[0] system with another text throws", W + "SIWCBody.swift",
     "                guard text == typedPrompt else { throw Failure(reason: \"input[0] is a system item that is not the typed prompt\") }\n", ""),
    ("S31 max_output_tokens is not stripped", "body: every unsupported field is stripped", W + "SIWCBody.swift",
     "[\"truncation\", \"max_output_tokens\", \"background\",", "[\"truncation\", \"background\","),
    ("S32 tools are not namespaced", "body: all function tools wrapped", W + "SIWCBody.swift",
     "        guard let tools = body[\"tools\"]?.responsesArray, !tools.isEmpty else { return body }",
     "        guard let tools = body[\"tools\"]?.responsesArray, tools.isEmpty else { return body }"),
    ("S33 system notes are rewritten to developer", "body: later system notes keep role", W + "SIWCBody.swift",
     "    static func namespaced(_ items: [JSONValue]) throws -> [JSONValue] {\n        try items.map { item in\n",
     "    static func namespaced(_ items: [JSONValue]) throws -> [JSONValue] {\n        try items.map { item in\n            if isSystemItem(item), var o = item.responsesObject { o[\"role\"] = .string(\"developer\"); return .object(o) }\n"),
    ("S34 the destination check accepts any openai.com host", "dest: subdomain refused", W + "SIWCBody.swift",
     "              parts.scheme == \"https\", parts.host == SIWCEndpoint.apiHost, parts.port == nil,",
     "              parts.scheme == \"https\", parts.host?.hasSuffix(SIWCEndpoint.apiHost) == true, parts.port == nil,"),
    ("S35 a call without a namespace is decoded", "decode: a missing namespace is rejected", S + "ResponsesModels.swift",
     "                if let requiredNamespace, item[\"namespace\"]?.responsesString != requiredNamespace {",
     "                if let requiredNamespace, item[\"namespace\"] != nil, item[\"namespace\"]?.responsesString != requiredNamespace {"),
    ("S36 session_id uses the legacy derivation", "session_id: never the legacy derivation", W + "SIWCRoute.swift",
     "    var affinityKey: String { \"briglia-siwc-v1:\" + identityFingerprint }", "    var affinityKey: String { \"briglia-subscription-v1:\" + generation }"),
    # The pre-send gate and the in-flight registry are independent layers
    # (either alone refuses a fenced send), so each is broken on its own.
    ("S37 the fence check admits a fenced registration", "fence: the pre-send check refuses after the fence", W + "SIWCFence.swift",
     "        guard !fenced.contains(key), epochs[key, default: 0] == capturedEpoch else {", "        guard true else {"),
    ("S51 the in-flight registry admits a fenced registration", "fence: a request started after the fence is refused", W + "SIWCFence.swift",
     "        guard !fenced.contains(key), epochs[key, default: 0] == epoch else {", "        guard true else {"),
    # Codex round 1 (CHATGPT_SIWC_IMPL_AB_CODEX_REVIEW_2026-11-06), R1–R8.
    ("S52 R1 a record changed during the refresh counts as unchanged", "R1: a rebound replacement during the refresh is kept", W + "SIWCStore+Refresh.swift",
     "                      Self.boundState(disk) == sent else { return false }", "                      true else { return false }"),
    ("S53 R2 the checkpoint is stamped with the registration's subject", "R2: a checkpoint of another account's tokens is never promoted", W + "SIWCStore+Refresh.swift",
     "            let newIdentity = updated.claims.map { Self.identity(key: key, sub: $0.sub, accountId: $0.accountId) } ?? oldIdentity",
     "            let newIdentity = updated.claims.map { Self.identity(key: key, sub: registration.sub, accountId: $0.accountId) } ?? oldIdentity"),
    ("S54 R3 admission is ignored", "R3: a send fenced before admission never starts", W + "SIWCFence.swift",
     "        let token = try register(key, epoch: epoch) { handle.cancel() }", "        let token = (try? register(key, epoch: epoch) { handle.cancel() }) ?? UUID()"),
    ("S55 R4 the models fetch is not registered under its registration", "R4: the models fetch is registered and cancelled", W + "ResponsesAdapter+SIWC.swift",
     "try await SIWCFence.shared.runRegistered(source.fenceKey, epoch: source.epoch) {\n            if let override { return try await override(pending) }",
     "try await SIWCFence.shared.runRegistered(source.fenceKey + \"-x\", epoch: 0) {\n            if let override { return try await override(pending) }"),
    ("S56 R5 every web round recaptures the route", "R5: every round of a web run uses the source captured", S + "SubscriptionWebTransport.swift",
     "        switch operation ?? SIWCOperationCapture.capture() {", "        switch SIWCOperationCapture.capture() {"),
    ("S57 R6 identity-only grants are refused", "R6: an identity-only response parses", W + "SIWCSignIn.swift",
     "            return (nil, idToken)   // identity only", "            throw SIWCError(.local, \"no refresh\")   // identity only"),
    ("S58 R7 the recovery records are outside the binding", "R7: clearing the recovery records breaks the binding", W + "SIWCStore.swift",
     "        copy.pendingRotation = nil\n        copy.cleanup = nil", "        copy.pendingRotation = nil; copy.refreshOp = nil; copy.refreshRecovery = nil\n        copy.cleanup = nil"),
    ("S59 R8 the host census skips extras without readable metadata", "R8: an extra with corrupt metadata still counts", W + "SIWCHost.swift",
     "                case .directory: out.append(url)", "                case .directory: if AssistantProfile.readMetadata(name) != nil { out.append(url) }"),
    ("S60 an expired token is refreshed before earliest_refresh_at", "dev4: never before earliest_refresh_at without a 401", W + "SIWCStore+Refresh.swift",
     "            if !rejected && (!due || !earliestOK) { return old }", "            if !rejected && (!due || (!earliestOK && old.expiresAt > now)) { return old }"),
    # Codex round 2 (…_ROUND2_2026-11-06): R5 and R8 remainders.
    ("S61 web stages recapture the route per call", "R5: one web_fetch never moves to another account", S + "WebOrchestrator.swift",
     "timeout: max(timeout, 120), deadline: deadline,\n                                                                   operation: try capturedOperation(executionID))",
     "timeout: max(timeout, 120), deadline: deadline,\n                                                                   operation: nil)"),
    ("S62 a provider switch moves a captured SIWC stage", "R5: stage dispatch keeps a captured SIWC run on SIWC", S + "WebOrchestrator.swift",
     "        case .source?, .failure?: return .chatgpt", "        case .source?, .failure?: return current"),
    ("S63 an lstat failure counts as absent", "R8: an unsearchable parent makes the census uncertain", W + "SIWCHost.swift",
     "        if lstat(path, &link) != 0 { return errno == ENOENT ? .absent : .uncertain }", "        if lstat(path, &link) != 0 { return .absent }"),
    ("S38 an ambiguous selection lets web move elsewhere", "web: an ambiguous SIWC selection still follows", S + "WebOrchestrator.swift",
     "        case .siwc, .ambiguous, .disabled: return true\n        case .legacy, .notChatGPT: break\n        }\n        guard stored[ProviderProfiles.activeProfileKey]",
     "        case .siwc: return true\n        case .ambiguous, .disabled: return false\n        case .legacy, .notChatGPT: break\n        }\n        guard stored[ProviderProfiles.activeProfileKey]"),
    ("S39 a legacy binding beside SIWC is not ambiguous", "route: a legacy binding beside the SIWC route is ambiguous", W + "SIWCRoute.swift",
     "        guard stored[ProviderProfiles.subscriptionGenerationKey] == nil, slot.isEmpty,", "        guard slot.isEmpty,"),
    ("S40 the kill switch is ignored", "route: the kill switch disables the SIWC route", W + "SIWCRoute.swift",
     "        if SIWCEndpoint.disabledByEnvironment(environment) { return .disabled }", "        _ = environment"),
    ("S41 SIWC is priced as paid API", "spend: SIWC on api.openai.com is never priced as paid API", S + "ResearchSpend.swift",
     "        guard !context.isChatGPTPlan else { return false }", "        guard context.subscriptionGeneration == nil else { return false }"),
    ("S42 SIWC is booked as OpenAI API usage", "usage: SIWC is booked in the subscription bucket", S + "ResponsesUsage.swift",
     "        let provider: Provider = context.isChatGPTPlan ? .subscription", "        let provider: Provider = context.subscriptionGeneration != nil ? .subscription"),
    ("S43 capture ignores the store's active registration", "capture: another registration active", W + "SIWCRoute.swift",
     "        guard SIWCEndpoint.registrationFingerprint(clientId: active) == selection.registrationFingerprint,\n              SIWCEndpoint.identityFingerprint(clientId: active, sub: registration.sub) == selection.identityFingerprint else {",
     "        guard true else {"),
    ("S44 the refresh request sends scope", "errors: 401 → exactly one refresh", W + "SIWCSignIn.swift",
     "                                              (\"refresh_token\", refreshToken), (\"resource\", SIWCEndpoint.resource)])",
     "                                              (\"refresh_token\", refreshToken), (\"resource\", SIWCEndpoint.resource), (\"scope\", \"openid\")])"),
    ("S45 a returning sign-in carries agent_name_hint", "authorize: returning sign-in uses the issued client", W + "SIWCSignIn.swift",
     "        if attempt.newRegistration { items.append((\"agent_name_hint\"", "        if true { items.append((\"agent_name_hint\""),
    ("S46 the store lock is not taken", "refresh: two processes on one store", W + "SIWCStore.swift",
     "        let deadline = ProcessInfo.processInfo.systemUptime + lockWait\n        while flock(fd, LOCK_EX | LOCK_NB) != 0 {",
     "        let deadline = ProcessInfo.processInfo.systemUptime + lockWait\n        while false && flock(fd, LOCK_EX | LOCK_NB) != 0 {"),
    ("S47 a returning sign-in with another sub is saved", "store: a returning sign-in with another sub is refused", W + "SIWCStore+Login.swift",
     "                    guard let existing, existing.sub == result.claims.sub else {", "                    guard existing != nil else {"),
    ("S48 another assistant's pending sign-in is overridden", "pending: one per store; another assistant is refused", W + "SIWCStore.swift",
     "               (file.pendingLoginBy ?? AssistantProfile.defaultName) != (owner ?? AssistantProfile.defaultName) {",
     "               false {"),
    ("S49 a 200 SIWC stream without Content-Type is not read as SSE", "sse: a 200 SIWC stream with no Content-Type", S + "ResponsesStream.swift",
     "                self.assembler.subscription = subscription || siwc\n", "                self.assembler.subscription = subscription\n"),
    ("S50 the usage limit is retried", "errors: usage limit → no retry", W + "ResponsesAdapter+SIWC.swift",
     "                    retry = failure.kind == .transient\n                } else if case ResponsesFailure.http(let code, let after) = error {\n                    retry = [408, 409, 429, 500, 502, 503, 504].contains(code)\n                    if let after { delay = after }\n                } else if let e = error as? URLError {\n                    retry = [.timedOut, .networkConnectionLost, .cannotConnectToHost, .notConnectedToInternet].contains(e.code)\n                } else { retry = false }\n                if let limit",
     "                    retry = failure.kind == .transient || failure.kind == .limitReached\n                } else if case ResponsesFailure.http(let code, let after) = error {\n                    retry = [408, 409, 429, 500, 502, 503, 504].contains(code)\n                    if let after { delay = after }\n                } else if let e = error as? URLError {\n                    retry = [.timedOut, .networkConnectionLost, .cannotConnectToHost, .notConnectedToInternet].contains(e.code)\n                } else { retry = false }\n                if let limit"),
    # ---- Stage C (settings writer and several assistants); 6th field = selftest group ----
    ("C1 the SIWC selection keeps the legacy selection keys", "select: the SIWC selection removes this assistant's legacy selection keys",
     W + "SIWCSelection.swift", "        for key in legacySelectionKeys { delta[key] = String?.none }\n        return delta", "        return delta", "c-select"),
    ("C2 the runtime slot keeps a sentinel", "select: the runtime credential slot is deleted", W + "SIWCSelection.swift",
     "            KeychainHelper.openAICompatibleApiKeyKey: String?.none,", "            KeychainHelper.openAICompatibleApiKeyKey: \"siwc-sentinel\",", "c-select"),
    ("C3 an explicit legacy selection leaves the SIWC keys", "profiles: an explicit legacy selection removes the SIWC selection keys",
     S + "ProviderProfiles.swift", "                for key in SIWCSelection.selectionKeys { changes[key] = String?.none }", "                _ = SIWCSelection.selectionKeys", "c-select"),
    ("C4 copy-keys binds an unusable login", "copy-keys: an unusable login binds nothing", W + "SIWCSelection.swift",
     "              machineStore.usability(record, registration: registration, key: try? machineStore.integrityKey(create: false)) == .usable,",
     "              machineStore.usability(record, registration: registration, key: try? machineStore.integrityKey(create: false)) != .invalidClient,", "c-select"),
    ("C5 rebind ignores a pending sign-in", "rebind: none while a sign-in is pending in the store", W + "SIWCRebind.swift",
     "            guard let file = try store.readTokens(), file.pendingLogin == nil, let record", "            guard let file = try store.readTokens(), let record", "c-rebind"),
    ("C6 the rebind is not a maintenance write", "rebind: a maintenance write never supersedes a staged change", W + "SIWCRebind.swift",
     "            try SettingsSupersede.$maintenanceWrite.withValue(true) {", "            try SettingsSupersede.$maintenanceWrite.withValue(false) {", "c-rebind"),
    ("C7 capture never rebinds", "rebind: the next operation follows the same registration's new record", W + "SIWCRoute.swift",
     "        if rebind, (try? store.readTokens())?.record(active)?.generation != selection.generation {", "        if false, rebind {", "c-rebind"),
    ("C8 the rebind ignores the store's active registration", "rebind: its own check refuses when another registration is active", W + "SIWCRebind.swift",
     "            guard let registrations = try store.readRegistrations(), registrations.active == clientId,", "            guard let registrations = try store.readRegistrations(),", "c-rebind"),
    ("C9 activation skips its generation expectation", "activate: prepared from an older record state", SS + "SettingsWriter+SIWC.swift",
     "            guard record.generation == op.expectGeneration, op.projectedGeneration == record.generation,\n                  store.usability(",
     "            guard store.usability(", "c-writer"),
    ("C10 staging skips the type boundary", "boundary: staging refuses a change carrying an SIWC token", SS + "SettingsWriter.swift",
     "        if let why = SIWCTypeBoundary.violation(change) { throw SettingsCommitError.refused(why) }\n", "", "c-writer"),
    ("C11 the boundary does not scan for tokens", "boundary: a reply carrying an SIWC token is refused", SS + "SettingsWriter+SIWC.swift",
     "        for token in tokens(in: directories) where text.contains(token) { return message }\n", "", "c-writer"),
    ("C13 sign-out does not fence or bump the epoch", "logout: no further send from an operation that captured the old source", SS + "SettingsWriter+SIWC.swift",
     "        SIWCFence.shared.fenceAndBump(key)\n        await Self.siwcAfterFenceForTesting?()", "        await Self.siwcAfterFenceForTesting?()", "c-logout"),
    ("C14 sign-out does not cancel running requests", "logout: the running request was cancelled and drained", SS + "SettingsWriter+SIWC.swift",
     "        SIWCFence.shared.cancelAll(key)\n", "", "c-logout"),
    ("C15 the revoke runs while the token is held", "logout: the remote revoke runs after the commit token is released", SS + "SettingsWriter+SIWC.swift",
     "        release()\n        SIWCActivity.shared.beginRevoke()", "        SIWCActivity.shared.beginRevoke()", "c-logout"),
    ("C16 a failed tombstone is reported as signed out", "logout: a tombstone failure is partial", SS + "SettingsWriter+SIWC.swift",
     "            Self.finishAttempt(attempt, change: change, pending: nil, state: \"partial\", message: SIWCLogoutOutcome.partialMessage)\n            return .partial(SIWCLogoutOutcome.partialMessage)",
     "            Self.finishAttempt(attempt, change: change, pending: nil, state: \"partial\", message: SIWCLogoutOutcome.partialMessage)\n            return .signedOut(remoteConfirmed: false)", "c-logout"),
    ("C17 the interrupting phase is cancellable", "logout: a lifecycle operation during the drain does not cancel the holder", SS + "SettingsCommitGate.swift",
     "        holderPhase = .interrupting; holderCancel = nil", "        holderPhase = .preCommit", "c-logout"),
    ("C18 admission is not rechecked after the drain", "logout: admission closed during the drain", SS + "SettingsWriter+SIWC.swift",
     "        if let why = host?.admissionRefusal() ?? gate.admissionClosedReason {\n            return .partial(", "        if false, let why = host?.admissionRefusal() {\n            return .partial(", "c-logout"),
    ("C19 a timed-out drain clears the fence", "logout: a drain that timed out keeps the fence", SS + "SettingsWriter+SIWC.swift",
     "        if drained { SIWCFence.shared.unfence(key) }", "        SIWCFence.shared.unfence(key)", "c-logout"),
    ("C20 a stale sign-out is not refused", "logout: a stale sign-out is refused", SS + "SettingsWriter+SIWC.swift",
     "                if let expectedGeneration, record.generation != expectedGeneration {", "                if let expectedGeneration, record.generation != expectedGeneration, false {", "c-logout"),
    ("C21 mixed targets of one grouped effect count as applied", "recovery: B is never reported retired from A's marker", W + "SIWCRecovery.swift",
     "        return .unknown   // mixed targets", "        return .applied   // mixed targets", "c-recovery"),
    ("C22 a missing secrets marker is ignored", "recovery: SIWC activated but settings not saved", W + "SIWCRecovery.swift",
     "        if needsSecrets && !marker {\n            return (\"partial\", \"partly applied (\\(detail)); settings not saved\")\n        }\n", "", "c-recovery"),
    ("C23 unreadable evidence reads as not applied", "recovery: unreadable evidence", W + "SIWCRecovery.swift",
     "            return Dictionary(uniqueKeysWithValues: effect.targets.map { ($0, Evidence.unknown) })",
     "            return Dictionary(uniqueKeysWithValues: effect.targets.map { ($0, Evidence.notApplied) })", "c-recovery"),
    ("C24 a partial scope transition reads as nothing changed", "recovery: scope with legacy retired and SIWC not", W + "SIWCRecovery.swift",
     "        if legacy == .applied || siwc == .applied { return (\"partial\", detail) }\n", "", "c-recovery"),
    ("C25 a shared extra's wipe signs the shared login out", "wipe shared extra: nothing revoked", W + "SIWCLifecycle.swift",
     "            // `own` was retired by `retireOwn` before the scope moved.\n            clear(ctx, into: &result)",
     "            _ = await signOutAndRemove(ctx.machineStore, ctx, label: \"x\", into: &result)\n            clear(ctx, into: &result)", "c-wipe"),
    ("C26 the host is removed while a registration exists elsewhere", "wipe shared extra: the host file is kept", W + "SIWCHost.swift",
     "            guard users.isEmpty else { return .keptInUse }", "            _ = users", "c-wipe"),
    ("C27 default signs the shared login out with sharers", "wipe default with sharers", W + "SIWCLifecycle.swift",
     "            if others.isEmpty {\n                _ = await signOutAndRemove(ctx.machineStore", "            if true {\n                _ = await signOutAndRemove(ctx.machineStore", "c-wipe"),
    ("C28 a failed own retirement lets the scope move", "wipe own extra: a failed retirement keeps the scope own", W + "SIWCLifecycle.swift",
     "            result.ownRetirementFailed = true\n", "", "c-wipe"),
    ("C29 the host file is not protected", "files: the host file is protected", W + "SIWCLifecycle.swift",
     "        out.append(hostPaths.hostFile)\n", "", "c-files"),
    ("C30 redaction misses the staged replacement", "redaction: staged replacement", "TelegramConcierge/Utilities/CredentialCatalog.swift",
     "                add(\"staged\", record.staged?.tokens)\n", "", "c-files"),
    ("C31 a refresh settle is not tracked", "activity: a running refresh settle is tracked", W + "SIWCStore+Refresh.swift",
     "        SIWCActivity.shared.beginSettle()\n", "", "c-activity"),
    ("C32 a pending sign-in does not park the upgrade", "activity: a pending sign-in this process owns parks the upgrade", W + "SIWCSignIn.swift",
     "            SIWCActivity.shared.register(attempt, signIn: self)\n", "", "c-activity"),
    ("C33 a save ignores the replacement epoch", "save: refused after a wipe/import (epoch)", SS + "SettingsWriter+SIWC.swift",
     "        guard (try? ReplacementEpoch.read()) == request.epoch else { return await refuse(Self.epochMessage) }\n", "", "c-writer"),
    ("C34 an SIWC store write does not supersede a staged activation", "supersede: a later SIWC store write drops the staged activation", SS + "SettingsWriter.swift",
     "            if let op = change.siwc, URL(fileURLWithPath: op.store).standardizedFileURL.path == path { return true }\n", "", "c-writer"),
    ("C35 a promotion leaves the fence", "replacement: an admitted activation of a new generation clears the fence", SS + "SettingsWriter.swift",
     "                SIWCFence.shared.unfence(SIWCFence.key(store: URL(fileURLWithPath: op.store), clientId: op.clientId))", "                _ = op", "c-writer"),
    ("C36 SIWC locks are not taken", "locks: legacy auth lock, then SIWC lock", SS + "SettingsWriter.swift",
     "        guard let first = stores.first else { return try await withSIWCLocks(siwc, body) }", "        guard let first = stores.first else { return try await body() }", "c-writer"),
    ("C37 a 'login changed' refresh is swallowed and the send repeated", "login changed: exactly one inference request", W + "ResponsesAdapter+SIWC.swift",
     "                    _ = try await source.store.credential(clientId: source.clientId, generation: source.generation,\n                        rejectedAccess: usedAccess,",
     "                    _ = try? await source.store.credential(clientId: source.clientId, generation: source.generation,\n                        rejectedAccess: usedAccess,", "c-notes"),
    ("C38 save decides 'in use' without this assistant's binding", "save: route-neutral", SS + "SettingsWriter+SIWC.swift",
     "        do { try siwcJournal(attempt, label: \"ChatGPT sign-in\", kind: \"siwc-save\", effects: [effect]) } catch {",
     "        try? KeychainHelper.save(key: \"siwc-break\", value: \"1\")\n        do { try siwcJournal(attempt, label: \"ChatGPT sign-in\", kind: \"siwc-save\", effects: [effect]) } catch {", "c-writer"),
]


def run(cmd, cwd, timeout=None, env=None):
    return subprocess.run(cmd, cwd=cwd, capture_output=True, text=True, timeout=timeout, env=env)


def build(tree, scratch):
    r = run(["swift", "build", "--build-system", "native", *LINUX_JOBS, "--scratch-path", str(scratch)], tree, timeout=3600)
    if r.returncode != 0:
        raise RuntimeError("build failed:\n" + (r.stdout + r.stderr)[-3000:])
    out = run(["swift", "build", "--build-system", "native", "--scratch-path", str(scratch), "--show-bin-path"], tree).stdout.strip()
    return Path(out) / "briglia"


def selftest(binary, workdir, group=None):
    env = {k: v for k, v in os.environ.items() if not k.startswith("BRIGLIA_")}
    env["XDG_CONFIG_HOME"] = str(Path(workdir) / "outer-config")
    env["XDG_DATA_HOME"] = str(Path(workdir) / "outer-data")
    return run([str(binary), "__siwc-selftest"] + (["--only", group] if group else []), workdir, timeout=900, env=env)


def mutate(tree, rel, old, new):
    path = tree / rel
    text = path.read_text()
    if text.count(old) != 1:
        raise RuntimeError(f"break anchor moved: {rel}: {old[:80]!r} (found {text.count(old)})")
    path.write_text(text.replace(old, new))
    return text


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--keep-build")
    ap.add_argument("--only")
    ap.add_argument("--verbose", action="store_true")
    ap.add_argument("--check-anchors", action="store_true")
    args = ap.parse_args()
    if args.check_anchors:
        bad = 0
        for entry in BREAKS:
            label, _, rel, old, _ = entry[:5]
            n = (ROOT / rel).read_text().count(old)
            if n != 1:
                bad += 1
                print(f"✖ {label}: anchor found {n} time(s)")
        print(f"{len(BREAKS) - bad}/{len(BREAKS)} anchors unique")
        return 1 if bad else 0
    work = Path(tempfile.mkdtemp(prefix="briglia-siwcbreak-"))
    tree = work / "tree"
    tree.mkdir()
    for name in ("Package.swift", "Package.resolved"):
        shutil.copy2(ROOT / name, tree / name)
    shutil.copytree(ROOT / "TelegramConcierge", tree / "TelegramConcierge")
    scratch = Path(args.keep_build) if args.keep_build else work / "build"
    failures = executed = 0
    try:
        binary = build(tree, scratch)
        r = selftest(binary, work)
        ok = r.returncode == 0
        print(("✔" if ok else "✖") + " positive control: the unmodified copy passes", flush=True)
        if not ok:
            print((r.stdout + r.stderr)[-3000:])
            return 1
        for entry in BREAKS:
            label, check, rel, old, new = entry[:5]
            group = entry[5] if len(entry) > 5 else None
            if args.only and label.split()[0] not in args.only.split(","):
                continue
            original = mutate(tree, rel, old, new)
            try:
                binary = build(tree, scratch)
                r = selftest(binary, work, group)
                failed = [l for l in r.stdout.splitlines() if l.startswith("✖")]
                caught = r.returncode != 0 and any(l.startswith(f"✖ {check}") for l in failed)
                print(("✔" if caught else "✖") + f" {label}: '{check}' fails"
                      + (f" ({len(failed)} failing check(s))" if failed else ""), flush=True)
                failures += 0 if caught else 1
                executed += 1
                if not caught and args.verbose:
                    print((r.stdout + r.stderr)[-6000:])
            finally:
                (tree / rel).write_text(original)
    finally:
        shutil.rmtree(work, ignore_errors=True)
    print(f"\n{executed - failures}/{executed} deliberate breaks caught")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
