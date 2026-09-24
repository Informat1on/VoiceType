import Foundation

// JSONL record types for the replay harness (K3 contract,
// docs/plans/quality-tools.md §5). Split out of ReplayHarnessTests.swift
// purely for the 600-line file_length warning threshold.
//
// Optional properties are omitted from the encoded line when nil
// (JSONEncoder's synthesized Encodable calls encodeIfPresent for Optional) —
// this is what gives K3's "absent values omit the key, never null" for free.

struct ReplayRunHeader: Encodable {
    let kind = "run"
    let startedAt: String
    let mode: String
    let input: String
    let model: String
    let coreMLRequested: Bool
    let threads: Int
    let language: String
    let pipelineStamp: String
    let promptHash: String
    let promptSource: String
    let swiftWhisperRevision: String
    let buildConfig: String
    let loadMs: Int
}

struct ReplaySegmentJSON: Encodable {
    let text: String
    let startMs: Int
    let endMs: Int
}

struct ReplayHistorySnapshot: Encodable {
    let raw: String
    let text: String
    let pipelineStamp: String?
    let model: String?
    let asrMs: Int?
    let status: String?
}

struct ReplayRecordJSON: Encodable {
    let kind = "record"
    let key: String
    let audioFile: String?
    let audioSeconds: Double?
    let raw: String?
    let final: String?
    let removedTemplates: [String]?
    let segments: [ReplaySegmentJSON]?
    let transcribeMs: Int?
    let rtf: Double?
    let promptMatchesHistory: Bool?
    let comparableToHistory: Bool?
    let reference: String?
    let evalIssue: String?
    let history: ReplayHistorySnapshot?
    let error: String?
}

struct ReplaySummaryJSON: Encodable {
    let kind = "summary"
    let records: Int
    let errors: Int
    let transcribeP50Ms: Int
    let transcribeP95Ms: Int
    let totalAudioSeconds: Double
    let totalTranscribeMs: Int
}
