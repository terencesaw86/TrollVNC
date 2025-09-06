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

#import "TVNCClientListController.h"
#import "TVNCClientCell.h"

#import <UIKit/UIKit.h>
#import <arpa/inet.h>
#import <errno.h>
#import <netinet/in.h>
#import <string.h>
#import <sys/socket.h>
#import <unistd.h>

static const int kTvCtlPort = 46752;

@interface TVNCClientListController ()

@property(nonatomic, strong) NSArray<NSDictionary *> *clients;
@property(nonatomic, strong) UIBarButtonItem *dismissItem;
@property(nonatomic, strong) UIBarButtonItem *refreshItem;

@end

@implementation TVNCClientListController

- (void)viewDidLoad {
    [super viewDidLoad];

    self.title = NSLocalizedStringFromTableInBundle(@"Clients", @"Localizable", self.bundle, nil);
    self.clients = @[];

    UIRefreshControl *refreshControl = [UIRefreshControl new];
    [refreshControl addTarget:self action:@selector(refresh) forControlEvents:UIControlEventValueChanged];
    self.refreshControl = refreshControl;

    self.navigationItem.leftBarButtonItem = self.refreshItem;
    self.navigationItem.rightBarButtonItem = self.dismissItem;

    [self refresh];
}

#pragma mark - Getters

- (UIBarButtonItem *)dismissItem {
    if (!_dismissItem) {
        _dismissItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemClose
                                                                     target:self
                                                                     action:@selector(dismiss)];
    }
    return _dismissItem;
}

- (UIBarButtonItem *)refreshItem {
    if (!_refreshItem) {
        _refreshItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemRefresh
                                                                     target:self
                                                                     action:@selector(refresh)];
        _refreshItem.tintColor = self.primaryColor;
    }
    return _refreshItem;
}

#pragma mark - Networking

static NSData *TVNCReadAll(int fd, double timeoutSec) {
    NSMutableData *md = [NSMutableData data];
    struct timeval tv;
    tv.tv_sec = (int)timeoutSec;
    tv.tv_usec = (int)((timeoutSec - tv.tv_sec) * 1e6);
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv));
    uint8_t buf[2048];
    for (;;) {
        ssize_t n = recv(fd, buf, sizeof(buf), 0);
        if (n <= 0)
            break;
        [md appendBytes:buf length:(NSUInteger)n];
        if (n < (ssize_t)sizeof(buf))
            break;
    }
    return md;
}

static int TVNCSendLine(int fd, NSString *line) {
    NSString *ln = [line hasSuffix:@"\n"] ? line : [line stringByAppendingString:@"\n"];
    NSData *d = [ln dataUsingEncoding:NSUTF8StringEncoding];
    const uint8_t *p = d.bytes;
    size_t left = d.length;
    while (left > 0) {
        ssize_t n = send(fd, p, left, 0);
        if (n < 0) {
            if (errno == EINTR)
                continue;
            return -1;
        }
        if (n == 0)
            break;
        p += (size_t)n;
        left -= (size_t)n;
    }
    return 0;
}

static int TVNCConnect(void) {
    int fd = socket(AF_INET, SOCK_STREAM, 0);
    if (fd < 0)
        return -1;
    struct sockaddr_in addr;
    memset(&addr, 0, sizeof(addr));
    addr.sin_len = sizeof(addr);
    addr.sin_family = AF_INET;
    addr.sin_port = htons(kTvCtlPort);
    addr.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    if (connect(fd, (struct sockaddr *)&addr, sizeof(addr)) < 0) {
        close(fd);
        return -1;
    }
    return fd;
}

- (void)dismiss {
    [self dismissViewControllerAnimated:YES completion:nil];
}

- (void)refresh {
    [self.refreshControl beginRefreshing];

    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        int fd = TVNCConnect();
        if (fd < 0) {
            dispatch_async(dispatch_get_main_queue(), ^{
                [self.refreshControl endRefreshing];
                self.clients = @[];
                [self.tableView reloadData];
            });
            return;
        }

        TVNCSendLine(fd, @"list");
        NSData *data = TVNCReadAll(fd, 2.0);
        close(fd);

        NSString *tsv = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] ?: @"";
        NSArray<NSString *> *lines = [tsv componentsSeparatedByCharactersInSet:[NSCharacterSet newlineCharacterSet]];
        NSMutableArray *rows = [NSMutableArray array];
        BOOL first = YES;

        for (NSString *ln in lines) {
            if (ln.length == 0)
                continue;

            if (first) {
                first = NO;
                continue;
            } // skip header

            NSArray *cols = [ln componentsSeparatedByString:@"\t"];
            if (cols.count < 5)
                continue;

            [rows addObject:@{
                @"id" : cols[0],
                @"host" : cols[1],
                @"viewOnly" : cols[2],
                @"connectedAt" : cols[3],
                @"durationSec" : cols[4]
            }];
        }

        dispatch_async(dispatch_get_main_queue(), ^{
            [self.refreshControl endRefreshing];
            self.clients = rows;
            [self.tableView reloadData];
        });
    });
}

- (void)disconnectAtIndex:(NSInteger)idx {
    if (idx < 0 || idx >= self.clients.count)
        return;

    NSString *cid = self.clients[idx][@"id"] ?: @"";
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        int fd = TVNCConnect();
        if (fd >= 0) {
            TVNCSendLine(fd, [NSString stringWithFormat:@"disconnect %@", cid]);
            (void)TVNCReadAll(fd, 2.0);
            close(fd);
        }

        dispatch_async(dispatch_get_main_queue(), ^{
            [self refresh];
        });
    });
}

#pragma mark - Table

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return self.clients.count;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    static NSString *cellId = @"TVNCClientCell";
    TVNCClientCell *cell = (TVNCClientCell *)[tableView dequeueReusableCellWithIdentifier:cellId];
    if (!cell) {
        cell = [[TVNCClientCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:cellId];
        cell.bundle = self.bundle;
    }

    NSDictionary *c = self.clients[indexPath.row];
    NSString *cid = c[@"id"] ?: @"";
    NSString *host = c[@"host"] ?: @"";
    BOOL vo = [[c objectForKey:@"viewOnly"] boolValue] || [[c objectForKey:@"viewOnly"] isEqual:@"1"];
    double dur = [[c objectForKey:@"durationSec"] doubleValue];

    // Relative subtitle with localization: "Connected %@"
    NSString *subtitle = nil;
    static NSRelativeDateTimeFormatter *sFmt;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        sFmt = [NSRelativeDateTimeFormatter new];
        sFmt.unitsStyle = NSRelativeDateTimeFormatterUnitsStyleFull;
    });
    NSString *rel = [sFmt localizedStringFromTimeInterval:-dur];
    subtitle = [NSString
        stringWithFormat:NSLocalizedStringFromTableInBundle(@"Connected %@", @"Localizable", self.bundle, nil),
                         rel ?: @"-"];

    [cell configureWithId:cid host:host viewOnly:vo subtitle:subtitle primaryColor:self.primaryColor];
    cell.accessoryType = UITableViewCellAccessoryNone;
    return cell;
}

- (UISwipeActionsConfiguration *)tableView:(UITableView *)tableView
    trailingSwipeActionsConfigurationForRowAtIndexPath:(NSIndexPath *)indexPath {

    __weak typeof(self) weakSelf = self;
    UIContextualAction *kick = [UIContextualAction
        contextualActionWithStyle:UIContextualActionStyleDestructive
                            title:NSLocalizedStringFromTableInBundle(@"Disconnect", @"Localizable", self.bundle, nil)
                          handler:^(__kindof UIContextualAction *action, __kindof UIView *sourceView,
                                    void (^completionHandler)(BOOL)) {
                              [weakSelf disconnectAtIndex:indexPath.row];
                              if (completionHandler)
                                  completionHandler(YES);
                          }];

    UISwipeActionsConfiguration *config = [UISwipeActionsConfiguration configurationWithActions:@[ kick ]];
    config.performsFirstActionWithFullSwipe = YES;
    return config;
}

- (BOOL)tableView:(UITableView *)tableView canEditRowAtIndexPath:(NSIndexPath *)indexPath {
    return YES;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
}

// iOS 14 min: Provide long-press context menu with copy actions
- (UIContextMenuConfiguration *)tableView:(UITableView *)tableView
    contextMenuConfigurationForRowAtIndexPath:(NSIndexPath *)indexPath
                                        point:(CGPoint)point {
    if (indexPath.row < 0 || indexPath.row >= self.clients.count)
        return nil;
    NSDictionary *c = self.clients[indexPath.row];
    NSString *cid = c[@"id"] ?: @"";
    NSString *host = c[@"host"] ?: @"";

    return [UIContextMenuConfiguration
        configurationWithIdentifier:nil
                    previewProvider:nil
                     actionProvider:^UIMenu *_Nullable(NSArray<UIMenuElement *> *_Nonnull suggestedActions) {
                         UIAction *copyId =
                             [UIAction actionWithTitle:NSLocalizedStringFromTableInBundle(@"Copy ID", @"Localizable",
                                                                                          self.bundle, nil)
                                                 image:[UIImage systemImageNamed:@"doc.on.doc"]
                                            identifier:nil
                                               handler:^(__kindof UIAction *_Nonnull action) {
                                                   [UIPasteboard generalPasteboard].string = cid;
                                                   [self.notificationGenerator
                                                       notificationOccurred:UINotificationFeedbackTypeSuccess];
                                               }];
                         UIAction *copyHost =
                             [UIAction actionWithTitle:NSLocalizedStringFromTableInBundle(@"Copy Host", @"Localizable",
                                                                                          self.bundle, nil)
                                                 image:[UIImage systemImageNamed:@"globe"]
                                            identifier:nil
                                               handler:^(__kindof UIAction *_Nonnull action) {
                                                   [UIPasteboard generalPasteboard].string = host;
                                                   [self.notificationGenerator
                                                       notificationOccurred:UINotificationFeedbackTypeSuccess];
                                               }];
                         UIAction *disconnect =
                             [UIAction actionWithTitle:NSLocalizedStringFromTableInBundle(@"Disconnect Now", @"Localizable",
                                                                                          self.bundle, nil)
                                                 image:[UIImage systemImageNamed:@"xmark.circle"]
                                            identifier:nil
                                               handler:^(__kindof UIAction *_Nonnull action) {
                                                   [self disconnectAtIndex:indexPath.row];
                                               }];
                         disconnect.attributes = UIMenuElementAttributesDestructive;
                         return [UIMenu menuWithTitle:@"" children:@[ copyId, copyHost, disconnect ]];
                     }];
}

@end
