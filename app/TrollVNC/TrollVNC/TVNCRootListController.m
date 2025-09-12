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
#import <Preferences/PSSpecifier.h>
#import <UIKit/UIKit.h>
#import <arpa/inet.h>
#import <ifaddrs.h>
#import <net/if.h>
#import <signal.h>
#import <stdlib.h>
#import <string.h>
#import <sys/sysctl.h>

#import "StripedTextTableViewController.h"
#import "TVNCClientListController.h"
#import "TVNCRootListController.h"

// Minimal process enumeration to restart VNC service
static inline void TVNCEnumerateProcesses(void (^enumerator)(pid_t pid, NSString *executablePath, BOOL *stop)) {
    static int kMaximumArgumentSize = 0;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        size_t valSize = sizeof(kMaximumArgumentSize);
        if (sysctl((int[]){CTL_KERN, KERN_ARGMAX}, 2, &kMaximumArgumentSize, &valSize, NULL, 0) < 0) {
            kMaximumArgumentSize = 4096;
        }
    });

    size_t procInfoLength = 0;
    if (sysctl((int[]){CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0}, 4, NULL, &procInfoLength, NULL, 0) < 0) {
        return;
    }

    struct kinfo_proc *procInfo = (struct kinfo_proc *)calloc(1, procInfoLength + 1);
    if (!procInfo)
        return;
    if (sysctl((int[]){CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0}, 4, procInfo, &procInfoLength, NULL, 0) < 0) {
        free(procInfo);
        return;
    }

    char *argBuffer = (char *)calloc(1, (size_t)kMaximumArgumentSize + 1);
    if (!argBuffer) {
        free(procInfo);
        return;
    }

    int procInfoCnt = (int)(procInfoLength / sizeof(struct kinfo_proc));
    for (int i = 0; i < procInfoCnt; i++) {
        pid_t pid = procInfo[i].kp_proc.p_pid;
        if (pid <= 1)
            continue;

        size_t argSize = (size_t)kMaximumArgumentSize;
        if (sysctl((int[]){CTL_KERN, KERN_PROCARGS2, pid, 0}, 4, NULL, &argSize, NULL, 0) < 0)
            continue;
        memset(argBuffer, 0, argSize + 1);
        if (sysctl((int[]){CTL_KERN, KERN_PROCARGS2, pid, 0}, 4, argBuffer, &argSize, NULL, 0) < 0)
            continue;

        BOOL stop = NO;
        @autoreleasepool {
            NSString *exePath = [NSString stringWithUTF8String:(argBuffer + sizeof(int))] ?: @"";
            enumerator(pid, exePath, &stop);
        }
        if (stop)
            break;
    }

    free(argBuffer);
    free(procInfo);
}

static inline void TVNCRestartVNCService(void) {
    // Try to terminate trollvncserver; launchd should respawn it if configured.
    TVNCEnumerateProcesses(^(pid_t pid, NSString *executablePath, BOOL *stop) {
        if ([executablePath.lastPathComponent isEqualToString:@"trollvncserver"]) {
            int rc = kill(pid, SIGTERM);
            if (rc == 0) {
#if THEBOOTSTRAP
                [UIApplication.sharedApplication setApplicationIconBadgeNumber:0];
#endif
            }
        }
    });
}

// Resolve current IPv4/IPv6 address of interface en0 (Wi‑Fi). Prefer IPv4 if available.
static inline NSString *TVNCGetEn0IPAddress(void) {
    struct ifaddrs *ifaList = NULL;
    if (getifaddrs(&ifaList) != 0 || !ifaList)
        return nil;

    NSString *ipv4 = nil;
    NSString *ipv6 = nil;
    for (struct ifaddrs *ifa = ifaList; ifa; ifa = ifa->ifa_next) {
        if (!ifa->ifa_addr || !ifa->ifa_name)
            continue;
        if (strcmp(ifa->ifa_name, "en0") != 0)
            continue;
        if (!(ifa->ifa_flags & IFF_UP) || (ifa->ifa_flags & IFF_LOOPBACK))
            continue;

        sa_family_t fam = ifa->ifa_addr->sa_family;
        char buf[INET6_ADDRSTRLEN] = {0};
        if (fam == AF_INET) {
            const struct sockaddr_in *sin = (const struct sockaddr_in *)ifa->ifa_addr;
            if (inet_ntop(AF_INET, &sin->sin_addr, buf, sizeof(buf))) {
                ipv4 = [NSString stringWithUTF8String:buf];
            }
        } else if (fam == AF_INET6) {
            const struct sockaddr_in6 *sin6 = (const struct sockaddr_in6 *)ifa->ifa_addr;
            // Skip link-local addresses (fe80::) if possible
            if (IN6_IS_ADDR_LINKLOCAL(&sin6->sin6_addr)) {
                char tmp[INET6_ADDRSTRLEN] = {0};
                if (inet_ntop(AF_INET6, &sin6->sin6_addr, tmp, sizeof(tmp))) {
                    // Keep as fallback only if no other IPv6 found later
                    if (!ipv6)
                        ipv6 = [NSString stringWithUTF8String:tmp];
                }
            } else {
                char tmp[INET6_ADDRSTRLEN] = {0};
                if (inet_ntop(AF_INET6, &sin6->sin6_addr, tmp, sizeof(tmp))) {
                    ipv6 = [NSString stringWithUTF8String:tmp];
                }
            }
        }
    }
    freeifaddrs(ifaList);
    return ipv4 ?: ipv6; // prefer IPv4
}

@interface TVNCRootListController ()

@property(nonatomic, strong) UINotificationFeedbackGenerator *notificationGenerator;
@property(nonatomic, strong) UIColor *primaryColor;

@end

@implementation TVNCRootListController

#ifdef THEBOOTSTRAP
@synthesize bundle = _bundle;

- (NSBundle *)bundle {
    if (!_bundle) {
        _bundle = [NSBundle bundleWithPath:[[NSBundle mainBundle] pathForResource:@"TrollVNCPrefs" ofType:@"bundle"]];
    }
    return _bundle;
}
#endif

/* clangd behavior workarounds */
#define STRINGIFY(x) #x
#define EXPAND_AND_STRINGIFY(x) STRINGIFY(x)
#define MYNSSTRINGIFY(x)                                                                                               \
    ^{                                                                                                                 \
        NSString *str = [NSString stringWithUTF8String:EXPAND_AND_STRINGIFY(x)];                                       \
        if ([str hasPrefix:@"\""])                                                                                     \
            str = [str substringFromIndex:1];                                                                          \
        if ([str hasSuffix:@"\""])                                                                                     \
            str = [str substringToIndex:str.length - 1];                                                               \
        return str;                                                                                                    \
    }()

- (NSArray *)specifiers {
    if (!_specifiers) {
        NSMutableArray<PSSpecifier *> *specifiers = [self loadSpecifiersFromPlistName:@"Root" target:self];
        PSSpecifier *firstGroup = [specifiers firstObject];
        NSString *packageScheme = MYNSSTRINGIFY(THEOS_PACKAGE_SCHEME);
        if (!packageScheme.length) {
            packageScheme = @"legacy";
        }
        [firstGroup setProperty:[NSString stringWithFormat:NSLocalizedStringFromTableInBundle(
                                                               @"TrollVNC (%@) v%@", @"Localizable", self.bundle, nil),
                                                           packageScheme, @PACKAGE_VERSION]
                         forKey:@"footerText"];
        _specifiers = specifiers;
    }
    return _specifiers;
}

// Add Apply button in nav bar
- (void)viewDidLoad {
    [super viewDidLoad];

    _notificationGenerator = [[UINotificationFeedbackGenerator alloc] init];
    _primaryColor = [UIColor colorWithRed:35 / 255.0 green:158 / 255.0 blue:171 / 255.0 alpha:1.0];
    [[UISwitch appearanceWhenContainedInInstancesOfClasses:@[
        [self class],
    ]] setOnTintColor:_primaryColor];
    [[UISlider appearanceWhenContainedInInstancesOfClasses:@[
        [self class],
    ]] setMinimumTrackTintColor:_primaryColor];
    [self.view setTintColor:_primaryColor];

    self.navigationItem.backBarButtonItem = [[UIBarButtonItem alloc] initWithTitle:@"TrollVNC"
                                                                             style:UIBarButtonItemStylePlain
                                                                            target:nil
                                                                            action:nil];
    self.navigationItem.backBarButtonItem.tintColor = _primaryColor;

    UIBarButtonItem *applyItem = [[UIBarButtonItem alloc]
        initWithTitle:NSLocalizedStringFromTableInBundle(@"Apply", @"Localizable", self.bundle, nil)
                style:UIBarButtonItemStyleDone
               target:self
               action:@selector(applyChanges)];
    applyItem.tintColor = _primaryColor;

    UIBarButtonItem *clientsItem = [[UIBarButtonItem alloc]
        initWithTitle:NSLocalizedStringFromTableInBundle(@"Clients", @"Localizable", self.bundle, nil)
                style:UIBarButtonItemStylePlain
               target:self
               action:@selector(showClients)];
    clientsItem.tintColor = _primaryColor;

#if THEBOOTSTRAP
    BOOL isApp = YES;
#else
    BOOL isApp = NO;
#endif

    BOOL isPad = ([UIDevice currentDevice].userInterfaceIdiom == UIUserInterfaceIdiomPad);
    if (isApp || isPad) {
        self.navigationItem.leftBarButtonItem = clientsItem;
        self.navigationItem.rightBarButtonItem = applyItem;
    } else {
        self.navigationItem.rightBarButtonItems = @[
            applyItem,
            clientsItem,
        ];
    }
}

- (void)showClients {
    TVNCClientListController *vc = [[TVNCClientListController alloc] init];
    vc.bundle = self.bundle;
    vc.primaryColor = self.primaryColor;
    vc.notificationGenerator = self.notificationGenerator;
    UINavigationController *navController = [[UINavigationController alloc] initWithRootViewController:vc];
    [self.navigationController presentViewController:navController animated:YES completion:nil];
}

#pragma mark - Actions

- (void)applyChanges {
    // Resign first responder status
    [self.view endEditing:YES];

    // Validate ports before restarting service, using -readPreferenceValue: to get live edits
    int port = 5901;
    int httpPort = 0;
    NSString *revMode = @"none";

    PSSpecifier *portSpec = nil;
    PSSpecifier *httpPortSpec = nil;
    PSSpecifier *revModeSpec = nil;
    for (PSSpecifier *sp in [self specifiers]) {
        NSString *key = [sp propertyForKey:@"key"];
        if (!key)
            continue;
        if (!portSpec && [key isEqualToString:@"Port"])
            portSpec = sp;
        else if (!httpPortSpec && [key isEqualToString:@"HttpPort"])
            httpPortSpec = sp;
        else if (!revModeSpec && [key isEqualToString:@"ReverseMode"])
            revModeSpec = sp;
        if (portSpec && httpPortSpec && revModeSpec)
            break;
    }

    id portVal = portSpec ? [self readPreferenceValue:portSpec] : nil;
    if ([portVal isKindOfClass:[NSNumber class]]) {
        port = [portVal intValue];
    } else if ([portVal isKindOfClass:[NSString class]]) {
        port = [(NSString *)portVal intValue];
    }

    id httpPortVal = httpPortSpec ? [self readPreferenceValue:httpPortSpec] : nil;
    if ([httpPortVal isKindOfClass:[NSNumber class]]) {
        httpPort = [httpPortVal intValue];
    } else if ([httpPortVal isKindOfClass:[NSString class]]) {
        httpPort = [(NSString *)httpPortVal intValue];
    }

    BOOL portInvalid = (port < 1024 || port > 65535);
    BOOL httpInvalid = (httpPort != 0 && (httpPort < 1024 || httpPort > 65535));
    if (portInvalid || httpInvalid) {
        NSString *t = NSLocalizedStringFromTableInBundle(@"Invalid Port", @"Localizable", self.bundle, nil);
        NSString *msg = NSLocalizedStringFromTableInBundle(
            @"TCP/HTTP ports must be 1024..65535 (HTTP can be 0 to disable). The server will fallback to defaults.",
            @"Localizable", self.bundle, nil);
        NSString *ok = NSLocalizedStringFromTableInBundle(@"OK", @"Localizable", self.bundle, nil);

        UIAlertController *alert = [UIAlertController alertControllerWithTitle:t
                                                                       message:msg
                                                                preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:ok style:UIAlertActionStyleDefault handler:nil]];

        [self presentViewController:alert animated:YES completion:nil];
        return; // do not restart now
    }

    NSString *title = NSLocalizedStringFromTableInBundle(@"Apply Changes", @"Localizable", self.bundle, nil);
    NSString *message = NSLocalizedStringFromTableInBundle(@"Are you sure you want to restart the VNC service?",
                                                           @"Localizable", self.bundle, nil);

    id revModeVal = revModeSpec ? [self readPreferenceValue:revModeSpec] : nil;
    if ([revModeVal isKindOfClass:[NSString class]]) {
        revMode = (NSString *)revModeVal;
    }

    NSString *ipLine;
    BOOL isRevModeOn = [revMode caseInsensitiveCompare:@"none"] != NSOrderedSame;
    if (isRevModeOn) {
        NSString *modeFormat =
            NSLocalizedStringFromTableInBundle(@"Reverse Connection: %@", @"Localizable", self.bundle, nil);
        if ([revMode caseInsensitiveCompare:@"repeater"] == NSOrderedSame) {
            revMode = NSLocalizedStringFromTableInBundle(@"Repeater", @"Localizable", self.bundle, nil);
        } else {
            revMode = NSLocalizedStringFromTableInBundle(@"Viewer", @"Localizable", self.bundle, nil);
        }
        ipLine = [NSString stringWithFormat:modeFormat, revMode];
    } else {
        // Append current en0 IP on a second line, if available
        NSString *ip = TVNCGetEn0IPAddress();
        NSString *ipUnavailable = NSLocalizedStringFromTableInBundle(@"unavailable", @"Localizable", self.bundle, nil);
        NSString *ipFormat =
            NSLocalizedStringFromTableInBundle(@"Current IP Address: %@", @"Localizable", self.bundle, nil);
        ipLine = [NSString stringWithFormat:ipFormat, (ip.length ? ip : ipUnavailable)];
    }

    NSString *fullMessage = [NSString stringWithFormat:@"%@\n%@", message, ipLine];
    NSString *cancel = NSLocalizedStringFromTableInBundle(@"Cancel", @"Localizable", self.bundle, nil);
    NSString *restart = NSLocalizedStringFromTableInBundle(@"Restart", @"Localizable", self.bundle, nil);

    UIAlertController *alert = [UIAlertController alertControllerWithTitle:title
                                                                   message:fullMessage
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:cancel style:UIAlertActionStyleCancel handler:nil]];
    __weak typeof(self) weakSelf = self;
    [alert addAction:[UIAlertAction actionWithTitle:restart
                                              style:UIAlertActionStyleDestructive
                                            handler:^(UIAlertAction *_Nonnull action) {
                                                TVNCRestartVNCService();
                                                [weakSelf.notificationGenerator
                                                    notificationOccurred:UINotificationFeedbackTypeSuccess];
                                                [weakSelf.view endEditing:YES];
                                            }]];

    [self presentViewController:alert animated:YES completion:nil];
}

- (void)viewLogs {
    NSString *rootPath = [self.bundle bundlePath];
    do {
        if ([rootPath hasSuffix:@"/var/jb"] || [[rootPath lastPathComponent] hasPrefix:@".jbroot-"]) {
            // Found the jailbreak root
            break;
        }
        if ([rootPath isEqualToString:@"/"] || !rootPath.length) {
            // Reached the root without finding jailbreak root
            break;
        }
        rootPath = [rootPath stringByDeletingLastPathComponent];
    } while (YES);

    NSString *logsPath = [rootPath stringByAppendingPathComponent:@"tmp/trollvnc-stderr.log"];
    NSLog(@"XXLogs path: %@", logsPath);

    StripedTextTableViewController *logsVC = [[StripedTextTableViewController alloc] initWithPath:logsPath];
    logsVC.primaryColor = self.primaryColor;

    [logsVC setAutoReload:YES];
    [logsVC setMaximumNumberOfRows:1000];
    [logsVC setMaximumNumberOfLines:20];
    [logsVC setReversed:YES];
    [logsVC setAllowDismissal:YES];
    [logsVC setAllowMultiline:YES];
    [logsVC setAllowTrash:NO];
    [logsVC setAllowSearch:YES];
    [logsVC setAllowShare:YES];
    [logsVC setPullToReload:YES];
    [logsVC setTapToCopy:YES];
    [logsVC setPressToCopy:YES];
    [logsVC setPreserveEmptyLines:NO];
    [logsVC setRemoveDuplicates:NO];

    NSRegularExpression *rowRegex =
        [NSRegularExpression regularExpressionWithPattern:@"^\\d{4}-\\d{2}-\\d{2} \\d{2}:\\d{2}:\\d{2}\\b"
                                                  options:0
                                                    error:nil];

    [logsVC setRowPrefixRegularExpression:rowRegex];
    [logsVC setRowSeparator:@"\r\n"];
    [logsVC setTitle:NSLocalizedStringFromTableInBundle(@"View Logs", @"Localizable", self.bundle, nil)];
    [logsVC setLocalizationBundle:self.bundle];

    UINavigationController *navController = [[UINavigationController alloc] initWithRootViewController:logsVC];
    [self presentViewController:navController animated:YES completion:nil];
}

- (void)support {
    NSURL *url = [NSURL URLWithString:@"https://havoc.app/search/82Flex"];
    if ([[UIApplication sharedApplication] canOpenURL:url]) {
        [[UIApplication sharedApplication] openURL:url options:@{} completionHandler:nil];
    }
}

- (void)source {
    NSURL *url = [NSURL URLWithString:@"https://github.com/OwnGoalStudio/TrollVNC"];
    if ([[UIApplication sharedApplication] canOpenURL:url]) {
        [[UIApplication sharedApplication] openURL:url options:@{} completionHandler:nil];
    }
}

#pragma mark - UITableViewDataSource & UITableViewDelegate

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    // Color the last section (support) button blue
    NSArray *specs = [self specifiers];
    NSInteger groupCount = 0;
    for (PSSpecifier *sp in specs) {
        if ([[sp propertyForKey:@"cell"] isEqualToString:@"PSGroupCell"]) {
            groupCount++;
        }
    }
    NSInteger lastSection = groupCount - 2; // support group
    if (indexPath.section >= lastSection) {
        PSSpecifier *specifier = [self specifierAtIndexPath:indexPath];
        NSString *key = [specifier propertyForKey:@"cell"];
        if ([key isEqualToString:@"PSButtonCell"]) {
            UITableViewCell *cell = [super tableView:tableView cellForRowAtIndexPath:indexPath];
            cell.textLabel.textColor = self.primaryColor;
            cell.textLabel.highlightedTextColor = self.primaryColor;
            return cell;
        }
    }
    return [super tableView:tableView cellForRowAtIndexPath:indexPath];
}

- (void)tableView:(UITableView *)tableView
      willDisplayCell:(UITableViewCell *)cell
    forRowAtIndexPath:(NSIndexPath *)indexPath {
    PSSpecifier *specifier = [self specifierAtIndexPath:indexPath];
    NSString *key = [specifier propertyForKey:@"cell"];
    if ([key isEqualToString:@"PSSliderCell"]) {
        // Find any UILabel in the cell's content view recursively
        UILabel *label = [self findLabelInView:cell.contentView];
        if (label) {
            // Do something with the label
            [label sizeToFit];
        }
    }
}

#pragma mark - Helper Methods

- (UILabel *)findLabelInView:(UIView *)view {
    for (UIView *subview in view.subviews) {
        if ([subview isKindOfClass:[UILabel class]]) {
            return (UILabel *)subview;
        }
        UILabel *label = [self findLabelInView:subview];
        if (label) {
            return label;
        }
    }
    return nil;
}

@end
