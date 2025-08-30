#import <Foundation/Foundation.h>
#import <Preferences/PSSpecifier.h>
#import <UIKit/UIKit.h>
#import <signal.h>
#import <stdlib.h>
#import <string.h>
#import <sys/sysctl.h>

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
            kill(pid, SIGTERM);
        }
    });
}

@implementation TVNCRootListController

- (NSArray *)specifiers {
    if (!_specifiers) {
        _specifiers = [self loadSpecifiersFromPlistName:@"Root" target:self];
    }
    return _specifiers;
}

// Add Apply button in nav bar
- (void)viewDidLoad {
    [super viewDidLoad];
    UIBarButtonItem *applyItem = [[UIBarButtonItem alloc] initWithTitle:NSLocalizedStringFromTableInBundle(@"Apply", @"Localizable", self.bundle, nil)
                                                                  style:UIBarButtonItemStyleDone
                                                                 target:self
                                                                 action:@selector(applyChanges)];
    applyItem.tintColor = [UIColor systemRedColor];
    self.navigationItem.rightBarButtonItem = applyItem;
}

- (void)applyChanges {
    // Resign first responder status
    [self.view endEditing:YES];

    // Validate ports before restarting service, using -readPreferenceValue: to get live edits
    int port = 5901;
    int httpPort = 0;

    PSSpecifier *portSpec = nil;
    PSSpecifier *httpPortSpec = nil;
    for (PSSpecifier *sp in [self specifiers]) {
        NSString *key = [sp propertyForKey:@"key"];
        if (!key) continue;
        if (!portSpec && [key isEqualToString:@"Port"]) portSpec = sp;
        else if (!httpPortSpec && [key isEqualToString:@"HttpPort"]) httpPortSpec = sp;
        if (portSpec && httpPortSpec) break;
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
        NSString *msg = NSLocalizedStringFromTableInBundle(@"TCP/HTTP ports must be 1024..65535 (HTTP can be 0 to disable). The server will fallback to defaults.", @"Localizable", self.bundle, nil);
        NSString *ok = NSLocalizedStringFromTableInBundle(@"OK", @"Localizable", self.bundle, nil);
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:t message:msg preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:ok style:UIAlertActionStyleDefault handler:nil]];
        [self presentViewController:alert animated:YES completion:nil];
        return; // do not restart now
    }

    NSString *title = NSLocalizedStringFromTableInBundle(@"Apply Changes", @"Localizable", self.bundle, nil);
    NSString *message = NSLocalizedStringFromTableInBundle(@"Are you sure you want to restart the VNC service?", @"Localizable", self.bundle, nil);
    NSString *cancel = NSLocalizedStringFromTableInBundle(@"Cancel", @"Localizable", self.bundle, nil);
    NSString *restart = NSLocalizedStringFromTableInBundle(@"Restart", @"Localizable", self.bundle, nil);

    UIAlertController *alert = [UIAlertController alertControllerWithTitle:title
                                                                   message:message
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:cancel style:UIAlertActionStyleCancel handler:nil]];
    __weak typeof(self) weakSelf = self;
    [alert addAction:[UIAlertAction actionWithTitle:restart
                                              style:UIAlertActionStyleDestructive
                                            handler:^(UIAlertAction *_Nonnull action) {
                                                TVNCRestartVNCService();
                                                // Optionally give a tiny feedback
                                                [weakSelf.view endEditing:YES];
                                            }]];
    [self presentViewController:alert animated:YES completion:nil];
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

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    // Color the last section (support) button blue
    NSArray *specs = [self specifiers];
    NSInteger groupCount = 0;
    for (PSSpecifier *sp in specs) {
        if ([[sp propertyForKey:@"cell"] isEqualToString:@"PSGroupCell"]) {
            groupCount++;
        }
    }
    NSInteger lastSection = groupCount - 1; // support group
    if (indexPath.section == lastSection) {
        PSSpecifier *specifier = [self specifierAtIndexPath:indexPath];
        NSString *key = [specifier propertyForKey:@"cell"];
        if ([key isEqualToString:@"PSButtonCell"]) {
            UITableViewCell *cell = [super tableView:tableView cellForRowAtIndexPath:indexPath];
            UIColor *color = [UIColor systemBlueColor];
            cell.textLabel.textColor = color;
            cell.textLabel.highlightedTextColor = color;
            return cell;
        }
    }
    return [super tableView:tableView cellForRowAtIndexPath:indexPath];
}

@end
