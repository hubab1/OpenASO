enum AppleAdsPopularityFallbackMessaging {
    static let webConnectionRequired =
        "Apple's primary service didn't return a score for this keyword. "
        + "Connect your Apple Ads account in Settings so OpenASO can check Apple's web service too."

    static let anyConnectionRequired =
        "Connect Apple Ads using either the Platform API or Web Access in Settings."
}
