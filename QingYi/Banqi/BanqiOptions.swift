//
//  BanqiOptions.swift
//  清弈
//
//  移植自 Android：app/src/main/java/com/sijia/go/banqi/BanqiOptions.java
//  暗棋规则变体的集中开关。默认值 = 规则文档 v1 采用方案，与 Android 完全一致。
//

import Foundation

/// 暗棋规则开关。改口时只改这里，规则逻辑、协议与页面都不用动。
struct BanqiOptions {

    /// 1. 同级能否互吃：true = 可以（將吃將等）。
    static var equalRankCanCapture = true

    /// 2. 炮架能否是暗子：true = 可以。
    static var cannonScreenMayBeHidden = true

    /// 3. 炮能否走步吃子：false = 不可以（所有吃子都必须隔子跳吃）。
    static var cannonCanCaptureByStep = false

    /// 4. 首翻前谁先手：seatFirst / seatSecond。
    static var firstSeat = BanqiGame.seatFirst

    /// 5. 无进展和棋阈值（双方合计连续无吃子无翻子的步数）。
    static var drawIdlePlies = BanqiGame.drawIdlePlies

    /// 6. 联机座位 2 是否 180° 翻转显示（仅视觉，规则与坐标不变）。
    static var flipForSeat2 = true

    private init() {}
}
