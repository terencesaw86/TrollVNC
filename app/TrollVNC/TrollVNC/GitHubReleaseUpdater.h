/*
 This file is part of TrollVNC
 Copyright (c) 2025 82Flex <82flex@gmail.com> and contributors

 This program is free software; you can redistribute it and/or modify
 it under the terms of the GNU General Public License version 2
 as published by the Free Software Foundation.

 This program is distributed in the hope that it will be useful,
 but WITHOUT ANY WARRANTY; without even the implied warranty of
 MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
 GNU General Public License for more details.

 You should have received a copy of the GNU General Public License
 along with this program. If not, see <https://www.gnu.org/licenses/>.
*/

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@class DpkgVersion;

/// Lightweight model for a GitHub release we care about.
@interface GHReleaseInfo : NSObject <NSCopying, NSSecureCoding>
@property(class, nonatomic, readonly) BOOL supportsSecureCoding;
@property(nonatomic, copy) NSString *tagName;               // original tag_name from GitHub (e.g., "v1.2.3")
@property(nonatomic, copy) NSString *versionString;         // normalized for DpkgVersion compare (e.g., "1.2.3")
@property(nonatomic, copy, nullable) NSString *name;        // release name/title
@property(nonatomic, copy, nullable) NSString *body;        // release notes (markdown)
@property(nonatomic, copy, nullable) NSString *htmlURL;     // html_url
@property(nonatomic, copy, nullable) NSString *publishedAt; // ISO date string
@property(nonatomic, assign) BOOL prerelease;
@property(nonatomic, assign) BOOL isNewerThanCurrent;
@end

/// Strategy configuration for background update checks.
@interface GHUpdateStrategy : NSObject <NSCopying, NSSecureCoding>
@property(class, nonatomic, readonly) BOOL supportsSecureCoding;
@property(nonatomic, copy) NSString *repoFullName;                // e.g., "owner/repo"
@property(nonatomic, assign) NSTimeInterval minimumCheckInterval; // default 6 hours
@property(nonatomic, assign) NSInteger maxRetryCount;             // default 3
@property(nonatomic, assign) NSTimeInterval minRetryInterval;     // default 60s
@property(nonatomic, assign) BOOL includePrereleases;             // default NO
@property(nonatomic, copy, nullable) NSString *githubToken;       // optional PAT for higher rate limit
@end

typedef void (^GHUpdateCheckCompletion)(GHReleaseInfo *_Nullable latest, NSError *_Nullable error, BOOL fromCache);

/// A thread-safe singleton that checks GitHub Releases for updates and caches results.
@interface GitHubReleaseUpdater : NSObject

+ (instancetype)shared;
- (instancetype)init NS_UNAVAILABLE;

// Configure and start background checking. Current version required for comparison.
- (void)configureWithStrategy:(GHUpdateStrategy *)strategy currentVersion:(NSString *)currentVersion;

// Starts periodic checks. Safe to call multiple times.
- (void)start;

// Stops periodic checks and cancels in-flight request.
- (void)stop;

// Force a check now (respects pause/skip but ignores minimumCheckInterval).
- (void)checkNowWithCompletion:(nullable GHUpdateCheckCompletion)completion;

// Pause background checks until a future date or for a duration.
- (void)pauseUntil:(NSDate *)date;
- (void)pauseFor:(NSTimeInterval)interval;

// Skip a version (suppress notifications until a strictly greater one appears).
- (void)skipVersion:(NSString *)versionString;
- (void)clearSkippedVersion;

// Access cached latest release (may be stale). Returns nil if no cache.
- (nullable GHReleaseInfo *)cachedLatestRelease;

// Returns YES if there’s a newer version than current, using cache only.
- (BOOL)hasNewerVersionInCache;

@end

/// Posted when a newer release is detected after a network check.
FOUNDATION_EXPORT NSString *const GitHubReleaseUpdaterDidFindUpdateNotification;
/// Public error domain for GitHubReleaseUpdater
FOUNDATION_EXPORT NSString *const GitHubReleaseUpdaterErrorDomain;

NS_ASSUME_NONNULL_END
