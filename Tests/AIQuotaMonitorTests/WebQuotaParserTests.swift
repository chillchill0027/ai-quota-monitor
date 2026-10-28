import Foundation

enum WebQuotaParserTests {
    static func run() throws {
        let chinese = WebQuotaParser.parseGemini("""
        欢迎升级，优惠 50%
        周配额窗口
        已使用
        11%
        3 天后重置
        5小时窗口
        0% 剩余
        2 小时后重置
        """)
        XCTAssertEqual(chinese.fiveHour?.remainingPercent, 0)
        XCTAssertEqual(chinese.weekly?.remainingPercent, 89)
        XCTAssertEqual(chinese.weekly?.resetText, "3 天后重置")
        XCTAssertEqual(chinese.fiveHour?.resetText, "2 小时后重置")

        let english = WebQuotaParser.parseGemini("""
        5-hour limit
        31% used
        Resets
        Oct 26, 6:30 PM
        Weekly limit
        Remaining: 84%
        Resets in 4 days
        """)
        XCTAssertEqual(english.fiveHour?.remainingPercent, 69)
        XCTAssertEqual(english.weekly?.remainingPercent, 84)
        XCTAssertEqual(english.fiveHour?.resetText, "Resets Oct 26, 6:30 PM")

        let splitReset = WebQuotaParser.parseGemini("Weekly\n20% used\nResets\n7 days")
        XCTAssertEqual(splitReset.weekly?.remainingPercent, 80)
        XCTAssertEqual(splitReset.weekly?.resetText, "Resets 7 days")
        XCTAssertEqual(WebQuotaParser.parseGemini("7 天窗口 95% 剩余").weekly?.remainingPercent, 95)
        XCTAssertEqual(WebQuotaParser.parseGemini("5 hours\nRemaining\n100%").fiveHour?.remainingPercent, 100)
        XCTAssertEqual(WebQuotaParser.parseGemini("Weekly\n20% used\n80% remaining").weekly?.remainingPercent, 80)
        for text in ["10% used\n20% remaining", "Daily limit\n50% remaining", "5-hour limit\n33%",
                     "Weekly\n105% remaining", "Weekly\n.5% remaining", "Weekly\n1,100% remaining", "Weekly\n1e2% remaining", "Weekly\n-1% remaining", "Weekly\n20% used\n50% remaining",
                     "Weekly Contest\n80% remaining", "Weekly\n20% usedAnywhere", "Resets in 5 hours\n30% remaining",
                     "Weekly\nSome other unrelated feature\n99% remaining"] {
            let value = WebQuotaParser.parseGemini(text)
            XCTAssertEqual(value.hasValues, false)
        }
        let ambiguous = WebQuotaParser.parseGemini("5-hour limit\n20% used\n5-hour limit\n30% used\nWeekly\n85% remaining")
        XCTAssertNil(ambiguous.fiveHour)
        XCTAssertEqual(ambiguous.weekly?.remainingPercent, 85)
        let missing = WebQuotaParser.parseGemini("Weekly\n89% remaining")
        XCTAssertNil(missing.fiveHour)
        XCTAssertEqual(missing.weekly?.remainingPercent, 89)

        let cash = WebQuotaParser.parseMiMoBalance("现金余额\n¥ 678.90\n赠金余额 ¥10.00\n充值 ¥50.00")
        XCTAssertEqual(cash?.amount, 678.90)
        XCTAssertEqual(cash?.currency, "CNY")
        XCTAssertEqual(WebQuotaParser.parseMiMoBalance("Cash Balance: ¥ 0")?.amount, 0)
        XCTAssertEqual(WebQuotaParser.parseMiMoBalance("Cash Balance\n$ -1,234.50")?.amount, -1234.5)
        XCTAssertEqual(WebQuotaParser.parseMiMoBalance("Cash Balance (USD)\n0")?.currency, "USD")
        XCTAssertEqual(WebQuotaParser.parseMiMoBalance("现金余额：−0.5 元")?.amount, -0.5)
        XCTAssertEqual(WebQuotaParser.parseMiMoBalance("现金余额\n￥\n0.00")?.amount, 0)
        XCTAssertEqual(WebQuotaParser.parseMiMoBalance("账户现金余额：¥678.90")?.amount, 678.90)
        for text in ["Top up ¥50.00", "Alert Threshold ¥5.00", "账户余额 ¥678.90", "可用总余额 ¥20.00",
                     "赠金余额 ¥10.00", "Token Plan\n50% used", "Cash Balance\nTop up ¥50.00",
                     "Cash Balance: ¥1,23.00", "Cash Balance: ¥ NaN", "Cash Balance: 678.90",
                     "Cash Balance (USD): ¥678.90", "Cash Balance: ¥678.90\nCash Balance: ¥10.00", "Cash Balance: ¥678.90\nCash Balance: Unknown"] {
            XCTAssertNil(WebQuotaParser.parseMiMoBalance(text))
        }
        print("PASS: Gemini/MiMo semantic parser regression cases")
    }
}
