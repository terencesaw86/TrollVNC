/*
 This file is part of TrollVNC
 Copyright (c) 2025 82Flex <82flex@gmail.com> and contributors
*/

#import "TVNCClientListController.h"
#import <UIKit/UIKit.h>
#import <arpa/inet.h>
#import <errno.h>
#import <netinet/in.h>
#import <string.h>
#import <sys/socket.h>
#import <unistd.h>

@interface TVNCClientListController ()
@property(nonatomic, strong) NSArray<NSDictionary *> *clients; // parsed rows
@property(nonatomic, strong) UIRefreshControl *rc;
@end

@implementation TVNCClientListController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"Clients";
    self.clients = @[];

    UIRefreshControl *rc = [UIRefreshControl new];
    [rc addTarget:self action:@selector(refresh) forControlEvents:UIControlEventValueChanged];
    self.rc = rc;
    if (@available(iOS 10.0, *)) {
        self.refreshControl = rc;
    } else {
        [self.tableView addSubview:rc];
    }

    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithTitle:@"Refresh"
                                                                              style:UIBarButtonItemStylePlain
                                                                             target:self
                                                                             action:@selector(refresh)];
    [self refresh];
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
    addr.sin_port = htons(46752);
    addr.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    if (connect(fd, (struct sockaddr *)&addr, sizeof(addr)) < 0) {
        close(fd);
        return -1;
    }
    return fd;
}

- (void)refresh {
    [self.rc beginRefreshing];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        int fd = TVNCConnect();
        if (fd < 0) {
            dispatch_async(dispatch_get_main_queue(), ^{
                [self.rc endRefreshing];
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
            [self.rc endRefreshing];
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
    static NSString *cellId = @"clientCell";
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:cellId];
    if (!cell)
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:cellId];

    NSDictionary *c = self.clients[indexPath.row];
    NSString *cid = c[@"id"] ?: @"";
    NSString *host = c[@"host"] ?: @"";
    BOOL vo = [[c objectForKey:@"viewOnly"] boolValue] || [[c objectForKey:@"viewOnly"] isEqual:@"1"];
    double dur = [[c objectForKey:@"durationSec"] doubleValue];

    cell.textLabel.text = [NSString stringWithFormat:@"%@  %@%@", cid, host, vo ? @"  (view-only)" : @""];
    cell.detailTextLabel.text = [NSString stringWithFormat:@"%.1fs", dur];
    cell.accessoryType = UITableViewCellAccessoryNone;
    return cell;
}

- (UISwipeActionsConfiguration *)tableView:(UITableView *)tableView
    trailingSwipeActionsConfigurationForRowAtIndexPath:(NSIndexPath *)indexPath API_AVAILABLE(ios(11.0)) {
    __weak typeof(self) weakSelf = self;
    UIContextualAction *kick =
        [UIContextualAction contextualActionWithStyle:UIContextualActionStyleDestructive
                                                title:@"Disconnect"
                                              handler:^(__kindof UIContextualAction *action,
                                                        __kindof UIView *sourceView, void (^completionHandler)(BOOL)) {
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

@end
