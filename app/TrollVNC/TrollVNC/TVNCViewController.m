//
//  TVNCViewController.m
//  TrollVNC
//
//  Created by 82Flex on 9/1/25.
//

#import "TVNCViewController.h"
#import "TVNCServiceCoordinator.h"

#import <UserNotifications/UserNotifications.h>

@interface TVNCViewController ()

@property(nonatomic, weak) UIAlertController *alertController;
@property(nonatomic, strong) NSTimer *checkTimer;
@property(nonatomic, strong) NSBundle *localizationBundle;

@end

@implementation TVNCViewController {
    BOOL _isAlertPresented;
}

- (void)viewDidLoad {
    [super viewDidLoad];

    self.localizationBundle = [NSBundle bundleWithPath:[[NSBundle mainBundle] pathForResource:@"TrollVNCPrefs"
                                                                                       ofType:@"bundle"]];

    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(serviceStatusDidChange:)
                                                 name:TVNCServiceStatusDidChangeNotification
                                               object:nil];
}

- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];

    if (_isAlertPresented) {
        return;
    }

    UNUserNotificationCenter *center = [UNUserNotificationCenter currentNotificationCenter];
    [center getNotificationSettingsWithCompletionHandler:^(UNNotificationSettings * _Nonnull settings) {
        if (settings.authorizationStatus == UNAuthorizationStatusNotDetermined) {
            [center requestAuthorizationWithOptions:(UNAuthorizationOptionAlert | UNAuthorizationOptionSound | UNAuthorizationOptionBadge)
                                  completionHandler:^(BOOL granted, NSError * _Nullable error) {
                // No UI changes needed here; could log if desired.
            }];
        }
    }];

    if ([[TVNCServiceCoordinator sharedCoordinator] isServiceRunning]) {
        _isAlertPresented = YES;
        return;
    }

    UIAlertController *alert =
        [UIAlertController alertControllerWithTitle:NSLocalizedStringFromTableInBundle(@"Launching", @"Localizable",
                                                                                       self.localizationBundle, nil)
                                            message:nil
                                     preferredStyle:UIAlertControllerStyleAlert];

    [self presentViewController:alert animated:YES completion:nil];

    self.alertController = alert;
    self.checkTimer = [NSTimer scheduledTimerWithTimeInterval:1.0
                                                       target:self
                                                     selector:@selector(checkServiceStatus:)
                                                     userInfo:nil
                                                      repeats:YES];

    _isAlertPresented = YES;
}

- (void)checkServiceStatus:(NSTimer *)timer {
    [self reloadWithCoordinator:[TVNCServiceCoordinator sharedCoordinator]];
}

- (void)serviceStatusDidChange:(NSNotification *)aNoti {
    TVNCServiceCoordinator *coordinator = (TVNCServiceCoordinator *)aNoti.object;
    [self reloadWithCoordinator:coordinator];
}

- (void)reloadWithCoordinator:(TVNCServiceCoordinator *)coordinator {
    if (![coordinator isServiceRunning]) {
        return;
    }

    [self.alertController dismissViewControllerAnimated:YES completion:nil];
    self.alertController = nil;

    [self.checkTimer invalidate];
    self.checkTimer = nil;
}

@end
