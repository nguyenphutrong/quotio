//
//  test_effort_translator.swift
//  Quotio - Standalone test harness for EffortTranslator
//
//  No XCTest / no test target needed. Compile together with the production file:
//
//      swiftc -parse-as-library \
//          Quotio/Services/Proxy/EffortTranslator.swift \
//          scripts/test_effort_translator.swift \
//          -o /tmp/effort_test && /tmp/effort_test
//
//  Exits 0 on all-pass, 1 on any failure.
//

import Foundation

@main
struct EffortTranslatorTests {

    // MARK: - Assertion helpers

    static var failures: [String] = []
    static var passedCount = 0

    static func check(_ condition: Bool, _ description: String, file: StaticString = #file, line: UInt = #line) {
        if condition {
            passedCount += 1
            print("  ok   \(description)")
        } else {
            failures.append("\(description) [\(file):\(line)]")
            print("  FAIL \(description) [\(file):\(line)]")
        }
    }

    static func checkEqual<T: Equatable>(_ lhs: T, _ rhs: T, _ description: String, file: StaticString = #file, line: UInt = #line) {
        if lhs == rhs {
            passedCount += 1
            print("  ok   \(description)")
        } else {
            failures.append("\(description): expected \(rhs), got \(lhs) [\(file):\(line)]")
            print("  FAIL \(description): expected \(rhs), got \(lhs) [\(file):\(line)]")
        }
    }

    static func section(_ name: String) {
        print("\n[\(name)]")
    }

    // MARK: - Fixtures

    static func makeBody(effort: String?, extraKeys: [String: Any] = [:]) -> String {
        var json: [String: Any] = [
            "model": "claude-opus-4-7",
            "max_tokens": 4096,
            "messages": [["role": "user", "content": "hello"]]
        ]
        if let effort {
            json["output_config"] = ["effort": effort].merging(extraKeys, uniquingKeysWith: { a, _ in a })
        }
        let data = try! JSONSerialization.data(withJSONObject: json, options: [.sortedKeys])
        return String(data: data, encoding: .utf8)!
    }

    static func decode(_ body: String) -> [String: Any] {
        guard let data = body.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return [:] }
        return obj
    }

    // MARK: - Entry point

    static func main() {
        runAllTests()

        print("\n-----")
        print("Passed: \(passedCount)")
        print("Failed: \(failures.count)")
        if !failures.isEmpty {
            print("\nFailures:")
            for f in failures {
                print("  - \(f)")
            }
            exit(1)
        }
        print("All tests passed.")
        exit(0)
    }

    // MARK: - Tests

    static func runAllTests() {
        test01_Max_IsClampedToXHigh()
        test02_MAX_UppercaseIsClampedToo()
        test03_XHigh_PassesThrough()
        test04_High_PassesThrough()
        test05_Medium_PassesThrough()
        test06_Low_PassesThrough()
        test07_NoEffortField_BodyUnchangedByteForByte()
        test08_NoOutputConfigAtAll_FastPathBodyUnchanged()
        test09_MalformedJSON_BodyUnchanged()
        test10_UnknownEffortValue_PassesThrough()
        test11_OtherOutputConfigKeys_Preserved()
        test12_LargeBodyPerformanceSmokeTest()
    }

    static func test01_Max_IsClampedToXHigh() {
        section("1. effort=max → clamped to xhigh")
        let body = makeBody(effort: "max")
        let r = EffortTranslator.clampEffort(in: body)
        checkEqual(r.originalEffort, "max", "originalEffort recorded")
        checkEqual(r.rewrittenEffort, "xhigh", "rewrittenEffort is xhigh")
        check(r.didRewrite, "didRewrite is true")
        let oc = decode(r.newBody)["output_config"] as? [String: Any] ?? [:]
        checkEqual(oc["effort"] as? String, "xhigh", "body.output_config.effort == xhigh")
    }

    static func test02_MAX_UppercaseIsClampedToo() {
        section("2. effort=MAX (uppercase) → clamped to xhigh")
        let body = makeBody(effort: "MAX")
        let r = EffortTranslator.clampEffort(in: body)
        checkEqual(r.rewrittenEffort, "xhigh", "uppercase MAX also clamped")
        let oc = decode(r.newBody)["output_config"] as? [String: Any] ?? [:]
        checkEqual(oc["effort"] as? String, "xhigh", "body.output_config.effort == xhigh")
    }

    static func test03_XHigh_PassesThrough() {
        section("3. effort=xhigh → passthrough (OpenAI accepts xhigh natively)")
        let body = makeBody(effort: "xhigh")
        let r = EffortTranslator.clampEffort(in: body)
        check(!r.didRewrite, "no rewrite")
        checkEqual(r.originalEffort, "xhigh", "originalEffort recorded")
        check(r.rewrittenEffort == nil, "rewrittenEffort is nil")
        let oc = decode(r.newBody)["output_config"] as? [String: Any] ?? [:]
        checkEqual(oc["effort"] as? String, "xhigh", "body unchanged: effort stays xhigh")
    }

    static func test04_High_PassesThrough() {
        section("4. effort=high → passthrough")
        let body = makeBody(effort: "high")
        let r = EffortTranslator.clampEffort(in: body)
        check(!r.didRewrite, "no rewrite")
        checkEqual(r.newBody, body, "body bytes identical")
    }

    static func test05_Medium_PassesThrough() {
        section("5. effort=medium → passthrough")
        let body = makeBody(effort: "medium")
        let r = EffortTranslator.clampEffort(in: body)
        check(!r.didRewrite, "no rewrite")
        checkEqual(r.newBody, body, "body bytes identical")
    }

    static func test06_Low_PassesThrough() {
        section("6. effort=low → passthrough")
        let body = makeBody(effort: "low")
        let r = EffortTranslator.clampEffort(in: body)
        check(!r.didRewrite, "no rewrite")
        checkEqual(r.newBody, body, "body bytes identical")
    }

    static func test07_NoEffortField_BodyUnchangedByteForByte() {
        section("7. output_config present but no effort key → body unchanged")
        // Body has output_config for some other key, no effort field.
        let json: [String: Any] = [
            "model": "claude-opus-4-7",
            "output_config": ["some_future_key": "value"]
        ]
        let body = String(data: try! JSONSerialization.data(withJSONObject: json, options: [.sortedKeys]), encoding: .utf8)!
        let r = EffortTranslator.clampEffort(in: body)
        check(!r.didRewrite, "no rewrite")
        check(r.originalEffort == nil, "no originalEffort")
        checkEqual(r.newBody, body, "body bytes identical")
    }

    static func test08_NoOutputConfigAtAll_FastPathBodyUnchanged() {
        section("8. No output_config at all → fast path, body returned untouched")
        let body = makeBody(effort: nil)
        check(!body.contains("output_config"), "fixture has no output_config")
        let r = EffortTranslator.clampEffort(in: body)
        checkEqual(r.newBody, body, "body bytes identical")
        check(!r.didRewrite, "no rewrite")
    }

    static func test09_MalformedJSON_BodyUnchanged() {
        section("9. Malformed JSON → passes through untouched")
        let body = "{\"output_config\": malformed"
        let r = EffortTranslator.clampEffort(in: body)
        checkEqual(r.newBody, body, "body unchanged")
        check(!r.didRewrite, "no rewrite")
    }

    static func test10_UnknownEffortValue_PassesThrough() {
        section("10. Unknown effort value → passthrough, CLIProxyAPI decides")
        let body = makeBody(effort: "ultra-mega")
        let r = EffortTranslator.clampEffort(in: body)
        check(!r.didRewrite, "no rewrite for unknown value")
        checkEqual(r.originalEffort, "ultra-mega", "unknown value still reported")
        let oc = decode(r.newBody)["output_config"] as? [String: Any] ?? [:]
        checkEqual(oc["effort"] as? String, "ultra-mega", "body unchanged")
    }

    static func test11_OtherOutputConfigKeys_Preserved() {
        section("11. Other keys in output_config preserved when clamping")
        let json: [String: Any] = [
            "model": "claude-opus-4-7",
            "output_config": [
                "effort": "max",
                "some_other_key": "keep-me",
                "nested": ["a": 1] as [String: Any]
            ] as [String: Any]
        ]
        let body = String(data: try! JSONSerialization.data(withJSONObject: json, options: [.sortedKeys]), encoding: .utf8)!
        let r = EffortTranslator.clampEffort(in: body)
        checkEqual(r.rewrittenEffort, "xhigh", "clamped")
        let oc = decode(r.newBody)["output_config"] as? [String: Any] ?? [:]
        checkEqual(oc["effort"] as? String, "xhigh", "effort clamped")
        checkEqual(oc["some_other_key"] as? String, "keep-me", "sibling scalar preserved")
        let nested = oc["nested"] as? [String: Any] ?? [:]
        checkEqual(nested["a"] as? Int, 1, "sibling object preserved")
    }

    static func test12_LargeBodyPerformanceSmokeTest() {
        section("12. Large body (~250KB) with no output_config → fast path quick")
        let filler = String(repeating: "the quick brown fox ", count: 12000) // ~240KB
        let json: [String: Any] = [
            "model": "claude-opus-4-7",
            "messages": [
                ["role": "user", "content": filler]
            ]
        ]
        let body = String(data: try! JSONSerialization.data(withJSONObject: json, options: [.sortedKeys]), encoding: .utf8)!
        let start = Date()
        let r = EffortTranslator.clampEffort(in: body)
        let elapsedMs = Date().timeIntervalSince(start) * 1000
        checkEqual(r.newBody.count, body.count, "body length unchanged")
        check(!r.didRewrite, "no rewrite")
        check(elapsedMs < 100, "fast path completed in <100ms (took \(String(format: "%.2f", elapsedMs))ms)")
    }
}
