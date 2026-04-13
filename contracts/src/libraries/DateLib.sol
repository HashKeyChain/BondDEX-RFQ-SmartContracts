// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/// @title DateLib
/// @notice Lightweight date utilities for day-count convention calculations.
/// @dev Adapted from BokkyPooBah's DateTime Library (MIT) for the 30/360 US convention.
library DateLib {
    uint256 internal constant SECONDS_PER_DAY = 86_400;

    /// @notice Decomposes a Unix timestamp into (year, month, day) in UTC.
    /// @param timestamp Unix timestamp in seconds.
    /// @return year Calendar year.
    /// @return month Calendar month (1–12).
    /// @return day Calendar day (1–31).
    function toDate(
        uint256 timestamp
    ) internal pure returns (uint256 year, uint256 month, uint256 day) {
        unchecked {
            uint256 z = timestamp / SECONDS_PER_DAY + 719_468;
            uint256 era = z / 146_097;
            uint256 doe = z - era * 146_097;
            uint256 yoe = (doe - doe / 1460 + doe / 36_524 - doe / 146_096) /
                365;
            uint256 y = yoe + era * 400;
            uint256 doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
            uint256 mp = (5 * doy + 2) / 153;
            day = doy - (153 * mp + 2) / 5 + 1;
            month = mp < 10 ? mp + 3 : mp - 9;
            year = month <= 2 ? y + 1 : y;
        }
    }

    /// @notice Computes the day count between two timestamps using the 30/360 US convention.
    /// @dev Each month is treated as 30 days and each year as 360 days.
    /// @param fromTimestamp Start timestamp (inclusive).
    /// @param toTimestamp End timestamp (inclusive).
    /// @return dayCount Number of 30/360 days.
    function diffDays30_360(
        uint256 fromTimestamp,
        uint256 toTimestamp
    ) internal pure returns (uint256 dayCount) {
        (uint256 y1, uint256 m1, uint256 d1) = toDate(fromTimestamp);
        (uint256 y2, uint256 m2, uint256 d2) = toDate(toTimestamp);

        if (d1 == 31) d1 = 30;
        if (d2 == 31 && d1 >= 30) d2 = 30;

        unchecked {
            int256 result = int256(y2) *
                360 +
                int256(m2) *
                30 +
                int256(d2) -
                int256(y1) *
                360 -
                int256(m1) *
                30 -
                int256(d1);
            dayCount = result > 0 ? uint256(result) : 0;
        }
    }
}
