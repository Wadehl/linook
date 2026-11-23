import Foundation
import Testing
@testable import AiLimitsCore

@Suite("Antigravity 额度解析")
struct AntigravityLimitsTests {
    @Test("按客户端的分组与窗口生成额度，5 小时排在 7 天前面")
    func parsesGroups() throws {
        let response = try json(#"""
        {
          "groups": [
            {
              "displayName": "Gemini Models",
              "buckets": [
                {"bucketId": "gemini-weekly", "window": "weekly", "remainingFraction": 0.9619533, "resetTime": "2026-11-30T02:50:00Z"},
                {"bucketId": "gemini-5h", "window": "5h", "remainingFraction": 0.8805766, "resetTime": "2026-11-23T07:50:00Z"}
              ]
            },
            {
              "displayName": "Claude and GPT models",
              "buckets": [
                {"bucketId": "3p-weekly", "window": "weekly", "remainingFraction": 0.4886664, "resetTime": "2026-11-26T10:17:33Z"},
                {"bucketId": "3p-5h", "window": "5h", "remainingFraction": 1, "resetTime": "2026-11-23T12:03:05Z"}
              ]
            },
            {
              "displayName": "Gemini 4 Argon",
              "buckets": [
                {"bucketId": "gemini-argon-wtu-weekly", "window": "weekly", "remainingFraction": 1, "resetTime": "2026-11-30T07:03:05Z"}
              ]
            }
          ]
        }
        """#)

        let buckets = AntigravityLimitsProvider.buckets(from: response)
        #expect(buckets.map(\.name) == [
            "Gemini · 5 小时",
            "Gemini · 7 天",
            "Claude / GPT · 5 小时",
            "Claude / GPT · 7 天",
            "Gemini 4 Argon · 7 天"
        ])
        #expect(abs(buckets[0].window.usedPercent - 11.94234) < 0.0001)
        #expect(buckets[0].window.windowMinutes == 300)
        #expect(buckets[1].window.windowMinutes == 10_080)
        #expect(buckets[2].window.usedPercent == 0)
        #expect(buckets[0].window.resetsAt == isoDate("2026-11-23T07:50:00Z"))
        #expect(buckets[1].window.resetDescription != nil)
    }

    @Test("没有剩余比例的分组跳过")
    func skipsBucketsWithoutFraction() throws {
        let response = try json(#"""
        {
          "groups": [
            {"displayName": "Gemini 4 Carbon", "buckets": [{"bucketId": "gemini-4-carbon", "window": "weekly"}]}
          ]
        }
        """#)
        #expect(AntigravityLimitsProvider.buckets(from: response).isEmpty)
    }

    @Test("没有分组时返回空列表")
    func readsMissingGroups() throws {
        #expect(AntigravityLimitsProvider.buckets(from: try json(#"{}"#)).isEmpty)
    }

    @Test("账号信息取自 GetUserStatus")
    func readsAccount() throws {
        let root = try json(#"""
        {
          "userStatus": {
            "email": "someone@example.com",
            "planStatus": {"planInfo": {"planName": "Pro"}}
          }
        }
        """#)
        let account = try #require(AntigravityLimitsProvider.account(from: root))
        #expect(account.email == "someone@example.com")
        #expect(account.plan == "Pro")
    }

    @Test("没有登录状态时读不到账号")
    func readsSignedOut() throws {
        #expect(AntigravityLimitsProvider.account(from: try json(#"{}"#)) == nil)
    }

    private func json(_ text: String) throws -> [String: Any] {
        try #require(try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
    }

    private func isoDate(_ text: String) -> Date {
        ISO8601DateFormatter().date(from: text)!
    }
}
