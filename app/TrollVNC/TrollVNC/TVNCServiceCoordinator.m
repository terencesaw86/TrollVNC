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

#import "TVNCServiceCoordinator.h"
#import "TrollVNC-Swift.h"

#import <Foundation/Foundation.h>
#import <sys/socket.h>
#import <netinet/in.h>
#import <arpa/inet.h>

#define SERVICE_PORT 46751

@interface TVNCServiceCoordinator ()
@property(nonatomic, strong) NSTimer *checkTimer;
@end

@implementation TVNCServiceCoordinator

+ (instancetype)sharedCoordinator {
    static TVNCServiceCoordinator *sharedInstance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        sharedInstance = [[self alloc] init];
    });
    return sharedInstance;
}

+ (NSDictionary *)sharedTaskEnvironment {
    static NSDictionary *sharedEnvironment = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        NSMutableDictionary *env =
            [NSMutableDictionary dictionaryWithDictionary:[[NSProcessInfo processInfo] environment]];
        NSString *languageCode = [[NSLocale preferredLanguages] firstObject];
        if (languageCode) {
            env[@"TVNC_LANGUAGE_CODE"] = languageCode;
        }
        sharedEnvironment = [env copy];
    });
    return sharedEnvironment;
}

- (instancetype)init {
    self = [super init];
    if (self) {
    }
    return self;
}

#pragma mark - Public Methods

- (void)registerServiceMonitor {
    [_checkTimer invalidate];
    [self checkTimerFired:nil];
    _checkTimer = [NSTimer scheduledTimerWithTimeInterval:3.0
                                                   target:self
                                                 selector:@selector(checkTimerFired:)
                                                 userInfo:nil
                                                  repeats:YES];
}

#pragma mark - Private Methods

- (void)checkTimerFired:(NSTimer *_Nullable)timer {
    [self ensureServiceRunning];
}

- (void)ensureServiceRunning {
    if (![self isServiceRunning]) {
        [self spawnService];
    }
}

- (BOOL)isServiceRunning {
    int sockfd = socket(AF_INET, SOCK_STREAM, 0);
    if (sockfd < 0) {
        return NO;
    }
    
    struct sockaddr_in addr;
    memset(&addr, 0, sizeof(addr));
    addr.sin_family = AF_INET;
    addr.sin_addr.s_addr = inet_addr("127.0.0.1");
    addr.sin_port = htons(SERVICE_PORT);
    
    int result = connect(sockfd, (struct sockaddr *)&addr, sizeof(addr));
    close(sockfd);
    
    return result == 0;
}

- (void)spawnService {
    static TRTask *serviceTask = nil;
    serviceTask = [[TRTask alloc] init];

    NSString *executablePath = [[NSBundle mainBundle] pathForResource:@"trollvncmanager" ofType:@""];
    [serviceTask setExecutableURL:[NSURL fileURLWithPath:executablePath]];

    [serviceTask setUserIdentifier:0];
    [serviceTask setGroupIdentifier:0];

    [serviceTask setArguments:[NSArray array]];
    [serviceTask setEnvironment:[TVNCServiceCoordinator sharedTaskEnvironment]];

    NSError *error = nil;
    BOOL launched = [serviceTask launchAndReturnError:&error];
    if (!launched) {
#if DEBUG
        NSLog(@"[TVNC] Failed to launch service: %@", error);
#endif
        return;
    }

    int unused;
    waitpid(serviceTask.processIdentifier, &unused, WNOHANG);
}

@end
