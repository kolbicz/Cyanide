//
//  NiceBarSettingsSupport.m
//  Cyanide
//
//  NiceBar Lite Settings UI and weather helpers adapted from
//  https://github.com/d1y/cyanide-ios (AGPL-3.0).
//

#import "NiceBarSettingsSupport.h"
#import <CoreLocation/CoreLocation.h>
#import <math.h>
#import "LogTextView.h"

typedef NS_ENUM(NSInteger, CyanideNiceBarTrafficRange) {
    CyanideNiceBarTrafficRangeWeek = 0,
    CyanideNiceBarTrafficRangeMonth = 1,
    CyanideNiceBarTrafficRangeYear = 2,
};

@interface CyanideNiceBarTrafficItem : NSObject
@property (nonatomic, copy) NSString *label;
@property (nonatomic, assign) uint64_t bytes;
@end

@implementation CyanideNiceBarTrafficItem
@end

@interface CyanideNiceBarTrafficChartView : UIView
@property (nonatomic, copy) NSArray<CyanideNiceBarTrafficItem *> *items;
@end

@implementation CyanideNiceBarTrafficChartView

- (instancetype)initWithFrame:(CGRect)frame
{
    self = [super initWithFrame:frame];
    if (self) {
        self.backgroundColor = UIColor.clearColor;
        self.contentMode = UIViewContentModeRedraw;
    }
    return self;
}

- (void)setItems:(NSArray<CyanideNiceBarTrafficItem *> *)items
{
    _items = [items copy];
    [self setNeedsDisplay];
}

- (void)drawRect:(CGRect)rect
{
    CGContextRef ctx = UIGraphicsGetCurrentContext();
    if (!ctx) return;

    CGRect bounds = UIEdgeInsetsInsetRect(self.bounds, UIEdgeInsetsMake(10, 8, 18, 8));
    if (bounds.size.width <= 1 || bounds.size.height <= 1) return;

    [[UIColor.separatorColor colorWithAlphaComponent:0.55] setStroke];
    UIBezierPath *baseline = [UIBezierPath bezierPath];
    [baseline moveToPoint:CGPointMake(CGRectGetMinX(bounds), CGRectGetMaxY(bounds))];
    [baseline addLineToPoint:CGPointMake(CGRectGetMaxX(bounds), CGRectGetMaxY(bounds))];
    baseline.lineWidth = 1.0 / UIScreen.mainScreen.scale;
    [baseline stroke];

    NSUInteger count = self.items.count;
    if (count == 0) {
        NSDictionary *attrs = @{
            NSFontAttributeName: [UIFont systemFontOfSize:12],
            NSForegroundColorAttributeName: UIColor.secondaryLabelColor,
        };
        [@"No traffic history yet" drawInRect:bounds withAttributes:attrs];
        return;
    }

    uint64_t maxBytes = 1;
    for (CyanideNiceBarTrafficItem *item in self.items) {
        if (item.bytes > maxBytes) maxBytes = item.bytes;
    }

    CGFloat gap = count > 10 ? 3.0 : 6.0;
    CGFloat barWidth = MAX(4.0, (bounds.size.width - gap * (CGFloat)(count - 1)) / (CGFloat)count);
    UIColor *fill = UIColor.systemCyanColor;
    for (NSUInteger i = 0; i < count; i++) {
        CyanideNiceBarTrafficItem *item = self.items[i];
        CGFloat pct = maxBytes ? ((CGFloat)item.bytes / (CGFloat)maxBytes) : 0;
        CGFloat height = MAX(2.0, floor(bounds.size.height * pct));
        CGFloat x = CGRectGetMinX(bounds) + (barWidth + gap) * (CGFloat)i;
        CGRect bar = CGRectMake(x, CGRectGetMaxY(bounds) - height, barWidth, height);
        UIBezierPath *path = [UIBezierPath bezierPathWithRoundedRect:bar cornerRadius:MIN(3.0, barWidth / 2.0)];
        [[fill colorWithAlphaComponent:item.bytes == 0 ? 0.22 : 0.88] setFill];
        [path fill];
    }
}

@end

@interface CyanideNiceBarTrafficSummaryCell : UITableViewCell
@property (nonatomic, strong) UILabel *summaryLabel;
@property (nonatomic, strong) UILabel *detailLabelView;
@property (nonatomic, strong) CyanideNiceBarTrafficChartView *chartView;
- (void)configureWithTitle:(NSString *)title
                     total:(uint64_t)total
                     items:(NSArray<CyanideNiceBarTrafficItem *> *)items;
@end

@implementation CyanideNiceBarTrafficSummaryCell

- (instancetype)initWithStyle:(UITableViewCellStyle)style reuseIdentifier:(NSString *)reuseIdentifier
{
    self = [super initWithStyle:style reuseIdentifier:reuseIdentifier];
    if (!self) return nil;

    self.selectionStyle = UITableViewCellSelectionStyleNone;
    _summaryLabel = [[UILabel alloc] init];
    _summaryLabel.translatesAutoresizingMaskIntoConstraints = NO;
    _summaryLabel.font = [UIFont systemFontOfSize:16 weight:UIFontWeightSemibold];

    _detailLabelView = [[UILabel alloc] init];
    _detailLabelView.translatesAutoresizingMaskIntoConstraints = NO;
    _detailLabelView.font = [UIFont systemFontOfSize:13];
    _detailLabelView.textColor = UIColor.secondaryLabelColor;

    _chartView = [[CyanideNiceBarTrafficChartView alloc] initWithFrame:CGRectZero];
    _chartView.translatesAutoresizingMaskIntoConstraints = NO;

    [self.contentView addSubview:_summaryLabel];
    [self.contentView addSubview:_detailLabelView];
    [self.contentView addSubview:_chartView];

    UILayoutGuide *m = self.contentView.layoutMarginsGuide;
    [NSLayoutConstraint activateConstraints:@[
        [_summaryLabel.leadingAnchor constraintEqualToAnchor:m.leadingAnchor],
        [_summaryLabel.trailingAnchor constraintEqualToAnchor:m.trailingAnchor],
        [_summaryLabel.topAnchor constraintEqualToAnchor:m.topAnchor constant:2],
        [_detailLabelView.leadingAnchor constraintEqualToAnchor:m.leadingAnchor],
        [_detailLabelView.trailingAnchor constraintEqualToAnchor:m.trailingAnchor],
        [_detailLabelView.topAnchor constraintEqualToAnchor:_summaryLabel.bottomAnchor constant:3],
        [_chartView.leadingAnchor constraintEqualToAnchor:m.leadingAnchor],
        [_chartView.trailingAnchor constraintEqualToAnchor:m.trailingAnchor],
        [_chartView.topAnchor constraintEqualToAnchor:_detailLabelView.bottomAnchor constant:8],
        [_chartView.heightAnchor constraintEqualToConstant:96],
        [_chartView.bottomAnchor constraintEqualToAnchor:m.bottomAnchor constant:-2],
    ]];
    return self;
}

- (void)configureWithTitle:(NSString *)title
                     total:(uint64_t)total
                     items:(NSArray<CyanideNiceBarTrafficItem *> *)items
{
    self.summaryLabel.text = title;
    self.detailLabelView.text = [NSString stringWithFormat:@"Total %@", nicebarlite_format_traffic_bytes(total)];
    self.chartView.items = items;
}

@end

@interface CyanideNiceBarTrafficDetailCell : UITableViewCell
@end

@implementation CyanideNiceBarTrafficDetailCell

- (instancetype)initWithStyle:(UITableViewCellStyle)style reuseIdentifier:(NSString *)reuseIdentifier
{
    return [super initWithStyle:UITableViewCellStyleValue1 reuseIdentifier:reuseIdentifier];
}

@end

@interface CyanideNiceBarTrafficHistoryViewController ()
@property (nonatomic, assign) CyanideNiceBarTrafficRange selectedRange;
@property (nonatomic, copy) NSDictionary<NSString *, NSString *> *history;
@property (nonatomic, copy) NSArray<CyanideNiceBarTrafficItem *> *items;
@property (nonatomic, assign) uint64_t totalBytes;
@end

@implementation CyanideNiceBarTrafficHistoryViewController

- (instancetype)init
{
    self = [super initWithStyle:UITableViewStyleInsetGrouped];
    if (self) {
        self.title = @"Traffic History";
        _selectedRange = CyanideNiceBarTrafficRangeWeek;
    }
    return self;
}

- (void)viewDidLoad
{
    [super viewDidLoad];
    [self.tableView registerClass:CyanideNiceBarTrafficSummaryCell.class forCellReuseIdentifier:@"summary"];
    [self.tableView registerClass:CyanideNiceBarTrafficDetailCell.class forCellReuseIdentifier:@"detail"];
    self.history = nicebarlite_traffic_history_snapshot();
    [self rebuildItems];
}

- (NSDateFormatter *)dateFormatter
{
    NSDateFormatter *df = [[NSDateFormatter alloc] init];
    df.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
    df.dateFormat = @"yyyy-MM-dd";
    return df;
}

- (CyanideNiceBarTrafficItem *)itemWithLabel:(NSString *)label bytes:(uint64_t)bytes
{
    CyanideNiceBarTrafficItem *item = [[CyanideNiceBarTrafficItem alloc] init];
    item.label = label;
    item.bytes = bytes;
    return item;
}

- (void)rebuildItems
{
    NSMutableArray<CyanideNiceBarTrafficItem *> *items = [NSMutableArray array];
    NSCalendar *calendar = NSCalendar.currentCalendar;
    NSDate *now = [NSDate date];
    NSDateFormatter *keyFormatter = [self dateFormatter];
    self.totalBytes = 0;

    if (self.selectedRange == CyanideNiceBarTrafficRangeYear) {
        NSDateComponents *base = [calendar components:NSCalendarUnitYear | NSCalendarUnitMonth fromDate:now];
        for (NSInteger offset = 11; offset >= 0; offset--) {
            NSDateComponents *monthComp = [base copy];
            monthComp.month -= offset;
            NSDate *monthDate = [calendar dateFromComponents:monthComp];
            if (!monthDate) continue;
            NSRange days = [calendar rangeOfUnit:NSCalendarUnitDay inUnit:NSCalendarUnitMonth forDate:monthDate];
            NSDateComponents *labelComp = [calendar components:NSCalendarUnitMonth fromDate:monthDate];
            uint64_t monthTotal = 0;
            for (NSUInteger day = 1; day <= days.length; day++) {
                NSDateComponents *dayComp = [calendar components:NSCalendarUnitYear | NSCalendarUnitMonth fromDate:monthDate];
                dayComp.day = (NSInteger)day;
                NSString *key = [keyFormatter stringFromDate:[calendar dateFromComponents:dayComp]];
                monthTotal += (uint64_t)[self.history[key] longLongValue];
            }
            self.totalBytes += monthTotal;
            [items addObject:[self itemWithLabel:[NSString stringWithFormat:@"%ld月", (long)labelComp.month]
                                           bytes:monthTotal]];
        }
    } else {
        NSInteger daysBack = self.selectedRange == CyanideNiceBarTrafficRangeWeek ? 6 : 29;
        NSDateFormatter *labelFormatter = [[NSDateFormatter alloc] init];
        labelFormatter.dateFormat = self.selectedRange == CyanideNiceBarTrafficRangeWeek ? @"EEE" : @"M/d";
        for (NSInteger offset = daysBack; offset >= 0; offset--) {
            NSDate *date = [calendar dateByAddingUnit:NSCalendarUnitDay value:-offset toDate:now options:0];
            NSString *key = [keyFormatter stringFromDate:date];
            uint64_t bytes = (uint64_t)[self.history[key] longLongValue];
            self.totalBytes += bytes;
            [items addObject:[self itemWithLabel:[labelFormatter stringFromDate:date] bytes:bytes]];
        }
    }
    self.items = items;
}

- (NSString *)rangeTitle
{
    switch (self.selectedRange) {
        case CyanideNiceBarTrafficRangeWeek: return @"This Week";
        case CyanideNiceBarTrafficRangeMonth: return @"This Month";
        case CyanideNiceBarTrafficRangeYear: return @"This Year";
    }
    return @"Traffic";
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView
{
    return 3;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section
{
    if (section == 0 || section == 1) return 1;
    return (NSInteger)self.items.count;
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section
{
    if (section == 2) return self.selectedRange == CyanideNiceBarTrafficRangeYear ? @"Monthly Details" : @"Daily Details";
    return nil;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath
{
    if (indexPath.section == 0) {
        UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"range"];
        if (!cell) cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:@"range"];
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
        cell.textLabel.text = nil;
        for (UIView *view in [cell.contentView.subviews copy]) [view removeFromSuperview];
        UISegmentedControl *seg = [[UISegmentedControl alloc] initWithItems:@[@"Week", @"Month", @"Year"]];
        seg.translatesAutoresizingMaskIntoConstraints = NO;
        seg.selectedSegmentIndex = self.selectedRange;
        [seg addTarget:self action:@selector(rangeChanged:) forControlEvents:UIControlEventValueChanged];
        [cell.contentView addSubview:seg];
        [NSLayoutConstraint activateConstraints:@[
            [seg.leadingAnchor constraintEqualToAnchor:cell.contentView.layoutMarginsGuide.leadingAnchor],
            [seg.trailingAnchor constraintEqualToAnchor:cell.contentView.layoutMarginsGuide.trailingAnchor],
            [seg.topAnchor constraintEqualToAnchor:cell.contentView.layoutMarginsGuide.topAnchor],
            [seg.bottomAnchor constraintEqualToAnchor:cell.contentView.layoutMarginsGuide.bottomAnchor],
        ]];
        return cell;
    }
    if (indexPath.section == 1) {
        CyanideNiceBarTrafficSummaryCell *cell = [tableView dequeueReusableCellWithIdentifier:@"summary" forIndexPath:indexPath];
        [cell configureWithTitle:[self rangeTitle] total:self.totalBytes items:self.items];
        return cell;
    }

    CyanideNiceBarTrafficDetailCell *cell = [tableView dequeueReusableCellWithIdentifier:@"detail" forIndexPath:indexPath];
    CyanideNiceBarTrafficItem *item = self.items[(NSUInteger)indexPath.row];
    cell.textLabel.text = item.label;
    cell.detailTextLabel.text = nicebarlite_format_traffic_bytes(item.bytes);
    cell.selectionStyle = UITableViewCellSelectionStyleNone;
    return cell;
}

- (void)rangeChanged:(UISegmentedControl *)sender
{
    self.selectedRange = (CyanideNiceBarTrafficRange)sender.selectedSegmentIndex;
    [self rebuildItems];
    [self.tableView reloadData];
}

@end

NSString *CyanideNiceBarSystemName(NSInteger item)
{
    switch (item) {
        case NiceBarLiteSystemBatteryTemp: return @"Battery temp";
        case NiceBarLiteSystemFreeRAM: return @"Free RAM";
        case NiceBarLiteSystemBatteryPercent: return @"Battery %";
        case NiceBarLiteSystemNetworkSpeed: return @"Network speed";
        case NiceBarLiteSystemUptime: return @"Uptime";
        case NiceBarLiteSystemDate: return @"Date";
        case NiceBarLiteSystemLunarDate: return @"Lunar date";
        case NiceBarLiteSystemTodayTraffic: return @"Today traffic";
        case NiceBarLiteSystemCurrentIP: return @"Current IP";
        case NiceBarLiteSystemFreeDisk: return @"Free disk";
        case NiceBarLiteSystemThermalState: return @"Thermal state";
    }
    return @"System";
}

NSString *CyanideNiceBarSystemDescription(NSInteger item)
{
    switch (item) {
        case NiceBarLiteSystemBatteryTemp: return @"Battery sensor temperature.";
        case NiceBarLiteSystemFreeRAM: return @"Currently free memory.";
        case NiceBarLiteSystemBatteryPercent: return @"Current battery percentage.";
        case NiceBarLiteSystemNetworkSpeed: return @"Live download and upload speed.";
        case NiceBarLiteSystemUptime: return @"Time since the device last booted.";
        case NiceBarLiteSystemDate: return @"Current date.";
        case NiceBarLiteSystemLunarDate: return @"Chinese lunar date.";
        case NiceBarLiteSystemTodayTraffic: return @"Traffic counted today.";
        case NiceBarLiteSystemCurrentIP: return @"Current Wi-Fi IPv4 address.";
        case NiceBarLiteSystemFreeDisk: return @"Available storage.";
        case NiceBarLiteSystemThermalState: return @"Device heat level.";
    }
    return @"System status item.";
}

NSString *CyanideNiceBarSystemLanguageName(NSString *language)
{
    return [language isEqualToString:@"zh"] ? @"中文" : @"English";
}

NSString *CyanideNiceBarTimeFormatName(NSString *format)
{
    if ([format isEqualToString:@"HH:mm"]) return @"24h time";
    if ([format isEqualToString:@"h:mm a"]) return @"12h time";
    if ([format isEqualToString:@"HH:mm:ss"]) return @"Time + seconds";
    if ([format isEqualToString:@"EEE HH:mm"]) return @"Weekday + time";
    if ([format isEqualToString:@"a h:mm"]) return @"中文上下午";
    if ([format isEqualToString:@"M/d"]) return @"Short date";
    if ([format isEqualToString:@"MM/dd"]) return @"Date";
    if ([format isEqualToString:@"M/d EEE"]) return @"Date + weekday";
    if ([format isEqualToString:@"MM-dd HH:mm"]) return @"Date + time";
    if ([format isEqualToString:@"M月d日"]) return @"中文日期";
    if ([format isEqualToString:@"cyanide:cn-date-weekday"]) return @"中文日期+星期";
    if ([format isEqualToString:@"M月d日 EEE"]) return @"中文日期+星期";
    if ([format isEqualToString:@"cyanide:lunar"]) return @"Lunar date";
    if ([format isEqualToString:@"cyanide:lunar-cn"]) return @"农历";
    if ([format isEqualToString:@"cyanide:lunar-cn-full"]) return @"农历完整";
    return format.length ? format : @"HH:mm";
}

static NSString *CyanideNiceBarLunarCNPreview(BOOL full)
{
    NSCalendar *cal = [NSCalendar calendarWithIdentifier:NSCalendarIdentifierChinese];
    NSDateComponents *c = [cal components:NSCalendarUnitMonth | NSCalendarUnitDay fromDate:[NSDate date]];
    if (c.month <= 0 || c.day <= 0) return @"农历--";
    NSArray<NSString *> *months = @[@"正月", @"二月", @"三月", @"四月", @"五月", @"六月",
                                    @"七月", @"八月", @"九月", @"十月", @"冬月", @"腊月"];
    NSArray<NSString *> *days = @[@"初一", @"初二", @"初三", @"初四", @"初五", @"初六", @"初七", @"初八", @"初九", @"初十",
                                  @"十一", @"十二", @"十三", @"十四", @"十五", @"十六", @"十七", @"十八", @"十九", @"二十",
                                  @"廿一", @"廿二", @"廿三", @"廿四", @"廿五", @"廿六", @"廿七", @"廿八", @"廿九", @"三十"];
    NSString *month = c.month <= (NSInteger)months.count ? months[(NSUInteger)c.month - 1] : @"";
    NSString *day = c.day <= (NSInteger)days.count ? days[(NSUInteger)c.day - 1] : @"";
    if (!month.length || !day.length) return @"农历--";
    return full ? [NSString stringWithFormat:@"农历%@%@", month, day]
                : [NSString stringWithFormat:@"%@%@", month, day];
}

static BOOL CyanideNiceBarTimeFormatUsesChineseLocale(NSString *format)
{
    return [format isEqualToString:@"a h:mm"] ||
           [format rangeOfString:@"月"].location != NSNotFound;
}

static NSString *CyanideNiceBarChineseWeekdayPreview(void)
{
    NSInteger weekday = [[NSCalendar currentCalendar] component:NSCalendarUnitWeekday fromDate:[NSDate date]];
    NSArray<NSString *> *weekdays = @[@"", @"星期日", @"星期一", @"星期二", @"星期三", @"星期四", @"星期五", @"星期六"];
    if (weekday < 1 || weekday >= (NSInteger)weekdays.count) return @"星期-";
    return weekdays[(NSUInteger)weekday];
}

NSString *CyanideNiceBarPreviewForTimeFormat(NSString *format)
{
    if ([format isEqualToString:@"cyanide:lunar"]) {
        NSCalendar *cal = [NSCalendar calendarWithIdentifier:NSCalendarIdentifierChinese];
        NSDateComponents *c = [cal components:NSCalendarUnitMonth | NSCalendarUnitDay fromDate:[NSDate date]];
        if (c.month > 0 && c.day > 0) {
            return [NSString stringWithFormat:@"L%02ld/%02ld", (long)c.month, (long)c.day];
        }
        return @"Lunar --";
    }
    if ([format isEqualToString:@"cyanide:lunar-cn"]) return CyanideNiceBarLunarCNPreview(NO);
    if ([format isEqualToString:@"cyanide:lunar-cn-full"]) return CyanideNiceBarLunarCNPreview(YES);
    if ([format isEqualToString:@"cyanide:cn-date-weekday"] ||
        [format isEqualToString:@"M月d日 EEE"]) {
        return [NSString stringWithFormat:@"%@ %@",
                CyanideNiceBarPreviewForTimeFormat(@"M月d日"),
                CyanideNiceBarChineseWeekdayPreview()];
    }
    NSDateFormatter *formatter = [[NSDateFormatter alloc] init];
    formatter.locale = CyanideNiceBarTimeFormatUsesChineseLocale(format)
        ? [NSLocale localeWithLocaleIdentifier:@"zh_Hans_CN"]
        : [NSLocale currentLocale];
    formatter.dateFormat = format.length ? format : @"HH:mm";
    NSString *text = [formatter stringFromDate:[NSDate date]];
    return text.length ? text : @"--";
}

static NSArray<NSDictionary<NSString *, NSString *> *> *CyanideNiceBarTimePresets(void)
{
    return @[
        @{ @"section": @"Time", @"title": @"24h time",       @"format": @"HH:mm" },
        @{ @"section": @"Time", @"title": @"12h time",       @"format": @"h:mm a" },
        @{ @"section": @"Time", @"title": @"Time + seconds", @"format": @"HH:mm:ss" },
        @{ @"section": @"Time", @"title": @"Weekday + time", @"format": @"EEE HH:mm" },
        @{ @"section": @"Date", @"title": @"Short date",     @"format": @"M/d" },
        @{ @"section": @"Date", @"title": @"Date",           @"format": @"MM/dd" },
        @{ @"section": @"Date", @"title": @"Date + weekday", @"format": @"M/d EEE" },
        @{ @"section": @"Date", @"title": @"Date + time",    @"format": @"MM-dd HH:mm" },
        @{ @"section": @"中文", @"title": @"中文时间",        @"format": @"a h:mm" },
        @{ @"section": @"中文", @"title": @"中文日期",        @"format": @"M月d日" },
        @{ @"section": @"中文", @"title": @"中文日期+星期",    @"format": @"cyanide:cn-date-weekday" },
        @{ @"section": @"农历", @"title": @"Lunar date",     @"format": @"cyanide:lunar" },
        @{ @"section": @"农历", @"title": @"农历",           @"format": @"cyanide:lunar-cn" },
        @{ @"section": @"农历", @"title": @"农历完整",        @"format": @"cyanide:lunar-cn-full" },
    ];
}

@interface CyanideNiceBarTimePresetPickerViewController ()
@property (nonatomic, copy) NSString *selectedFormat;
@property (nonatomic, copy) CyanideNiceBarTimeFormatSelection selection;
@property (nonatomic, copy) NSArray<NSString *> *sectionTitles;
@property (nonatomic, copy) NSDictionary<NSString *, NSArray<NSDictionary<NSString *, NSString *> *> *> *sections;
@end

@implementation CyanideNiceBarTimePresetPickerViewController

- (instancetype)initWithSlotTitle:(NSString *)slotTitle
                   selectedFormat:(NSString *)selectedFormat
                        selection:(CyanideNiceBarTimeFormatSelection)selection
{
    self = [super initWithStyle:UITableViewStyleInsetGrouped];
    if (self) {
        self.title = slotTitle.length ? slotTitle : @"Date / Time";
        self.selectedFormat = selectedFormat.length ? selectedFormat : @"HH:mm";
        self.selection = selection;
        NSMutableArray<NSString *> *titles = [NSMutableArray array];
        NSMutableDictionary<NSString *, NSMutableArray *> *groups = [NSMutableDictionary dictionary];
        for (NSDictionary<NSString *, NSString *> *preset in CyanideNiceBarTimePresets()) {
            NSString *section = preset[@"section"] ?: @"Time";
            if (!groups[section]) {
                groups[section] = [NSMutableArray array];
                [titles addObject:section];
            }
            [groups[section] addObject:preset];
        }
        self.sectionTitles = titles;
        self.sections = groups;
    }
    return self;
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView
{
    return (NSInteger)self.sectionTitles.count;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section
{
    NSString *title = self.sectionTitles[(NSUInteger)section];
    return (NSInteger)self.sections[title].count;
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section
{
    return self.sectionTitles[(NSUInteger)section];
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath
{
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"preset"];
    if (!cell) cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"preset"];
    NSString *section = self.sectionTitles[(NSUInteger)indexPath.section];
    NSDictionary<NSString *, NSString *> *preset = self.sections[section][(NSUInteger)indexPath.row];
    NSString *format = preset[@"format"] ?: @"HH:mm";
    cell.textLabel.text = preset[@"title"] ?: format;
    cell.detailTextLabel.text = CyanideNiceBarPreviewForTimeFormat(format);
    cell.detailTextLabel.textColor = UIColor.secondaryLabelColor;
    cell.accessoryType = [format isEqualToString:self.selectedFormat]
        ? UITableViewCellAccessoryCheckmark
        : UITableViewCellAccessoryNone;
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath
{
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    NSString *section = self.sectionTitles[(NSUInteger)indexPath.section];
    NSString *format = self.sections[section][(NSUInteger)indexPath.row][@"format"] ?: @"HH:mm";
    if (self.selection) self.selection(format);
    [self.navigationController popViewControllerAnimated:YES];
}

@end

@interface CyanideNiceBarSystemItemPickerViewController ()
@property (nonatomic, assign) NSInteger selectedItem;
@property (nonatomic, copy) NSString *selectedLanguage;
@property (nonatomic, copy) CyanideNiceBarSystemItemSelection selection;
@end

@implementation CyanideNiceBarSystemItemPickerViewController

- (instancetype)initWithSlotTitle:(NSString *)slotTitle
                     selectedItem:(NSInteger)selectedItem
                 selectedLanguage:(NSString *)selectedLanguage
                        selection:(CyanideNiceBarSystemItemSelection)selection
{
    self = [super initWithStyle:UITableViewStyleInsetGrouped];
    if (self) {
        self.title = slotTitle.length ? slotTitle : @"System Item";
        self.selectedItem = selectedItem;
        self.selectedLanguage = selectedLanguage.length ? selectedLanguage : @"en";
        self.selection = selection;
    }
    return self;
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView
{
    return 2;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section
{
    return section == 0 ? NiceBarLiteSystemLast + 1 : 2;
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section
{
    return section == 0 ? @"System Item" : @"Thermal State Language";
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath
{
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"system"];
    if (!cell) cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"system"];
    if (indexPath.section == 0) {
        NSInteger item = indexPath.row;
        cell.textLabel.text = CyanideNiceBarSystemName(item);
        cell.detailTextLabel.text = CyanideNiceBarSystemDescription(item);
        cell.detailTextLabel.numberOfLines = 2;
        cell.accessoryType = item == self.selectedItem ? UITableViewCellAccessoryCheckmark : UITableViewCellAccessoryNone;
    } else {
        NSString *language = indexPath.row == 0 ? @"en" : @"zh";
        cell.textLabel.text = CyanideNiceBarSystemLanguageName(language);
        cell.detailTextLabel.text = indexPath.row == 0 ? @"Shows thermal state in English." : @"Shows thermal state in Chinese.";
        cell.accessoryType = [language isEqualToString:self.selectedLanguage] &&
                             self.selectedItem == NiceBarLiteSystemThermalState
            ? UITableViewCellAccessoryCheckmark
            : UITableViewCellAccessoryNone;
    }
    cell.detailTextLabel.textColor = UIColor.secondaryLabelColor;
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath
{
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    NSInteger item = indexPath.section == 0 ? indexPath.row : NiceBarLiteSystemThermalState;
    NSString *language = indexPath.section == 1
        ? (indexPath.row == 0 ? @"en" : @"zh")
        : self.selectedLanguage;
    if (self.selection) self.selection(item, language);
    [self.navigationController popViewControllerAnimated:YES];
}

@end

NSString *CyanideNiceBarWeatherSummary(NSInteger code, BOOL chinese)
{
    if (chinese) {
        switch (code) {
            case 0: return @"☀️ 晴";
            case 1: return @"🌤️ 晴转多云";
            case 2: return @"⛅️ 局部多云";
            case 3: return @"☁️ 阴";
            case 45:
            case 48: return @"🌫️ 雾";
            case 51:
            case 53:
            case 55: return @"🌦️ 毛毛雨";
            case 56:
            case 57: return @"🌧️ 冻毛毛雨";
            case 61:
            case 63:
            case 65: return @"🌧️ 雨";
            case 66:
            case 67: return @"🌧️ 冻雨";
            case 71:
            case 73:
            case 75:
            case 77: return @"❄️ 雪";
            case 80:
            case 81:
            case 82: return @"🌦️ 阵雨";
            case 85:
            case 86: return @"🌨️ 阵雪";
            case 95: return @"⛈️ 雷暴";
            case 96:
            case 99: return @"⛈️ 雷暴冰雹";
            default: return @"🌡️ 天气";
        }
    }
    switch (code) {
        case 0: return @"☀️ Clear";
        case 1: return @"🌤️ Mostly clear";
        case 2: return @"⛅️ Partly cloudy";
        case 3: return @"☁️ Cloudy";
        case 45:
        case 48: return @"🌫️ Fog";
        case 51:
        case 53:
        case 55: return @"🌦️ Drizzle";
        case 56:
        case 57: return @"🌧️ Freezing drizzle";
        case 61:
        case 63:
        case 65: return @"🌧️ Rain";
        case 66:
        case 67: return @"🌧️ Freezing rain";
        case 71:
        case 73:
        case 75:
        case 77: return @"❄️ Snow";
        case 80:
        case 81:
        case 82: return @"🌦️ Rain showers";
        case 85:
        case 86: return @"🌨️ Snow showers";
        case 95: return @"⛈️ Thunderstorm";
        case 96:
        case 99: return @"⛈️ Storm hail";
        default: return @"🌡️ Weather";
    }
}

@interface CyanideNiceBarWeatherRefresher () <CLLocationManagerDelegate>
@property (nonatomic, strong) CLLocationManager *locationManager;
@property (nonatomic, strong) NSMutableArray<CyanideNiceBarWeatherCompletion> *pendingCompletions;
@property (nonatomic, assign) BOOL locationRequestInFlight;
@property (nonatomic, assign) BOOL weatherFetchInFlight;
@property (nonatomic, assign) BOOL requestUsesCelsius;
@end

@implementation CyanideNiceBarWeatherRefresher

+ (instancetype)sharedRefresher
{
    static CyanideNiceBarWeatherRefresher *refresher;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        refresher = [[CyanideNiceBarWeatherRefresher alloc] init];
    });
    return refresher;
}

- (instancetype)init
{
    self = [super init];
    if (self) {
        _pendingCompletions = [NSMutableArray array];
    }
    return self;
}

- (void)refreshWeatherForce:(BOOL)force
                 useCelsius:(BOOL)useCelsius
                 completion:(CyanideNiceBarWeatherCompletion)completion
{
    dispatch_async(dispatch_get_main_queue(), ^{
        if (completion) [self.pendingCompletions addObject:[completion copy]];
        if (self.locationRequestInFlight || self.weatherFetchInFlight) {
            log_user("[NICEBAR] Weather flow already in progress.\n");
            return;
        }

        self.requestUsesCelsius = useCelsius;
        log_user("[NICEBAR] Weather flow starting force=%d celsius=%d.\n",
                 force ? 1 : 0,
                 useCelsius ? 1 : 0);
        if (!CLLocationManager.locationServicesEnabled) {
            log_user("[NICEBAR] Weather failed: location services disabled.\n");
            [self finishWithOK:NO text:@"Weather --" temp:nil code:nil fetched:NO];
            return;
        }
        if (!self.locationManager) {
            self.locationManager = [[CLLocationManager alloc] init];
            self.locationManager.delegate = self;
            self.locationManager.desiredAccuracy = kCLLocationAccuracyKilometer;
        }

        CLAuthorizationStatus status;
        if (@available(iOS 14.0, *)) {
            status = self.locationManager.authorizationStatus;
        } else {
            status = [CLLocationManager authorizationStatus];
        }

        if (status == kCLAuthorizationStatusNotDetermined) {
            log_user("[NICEBAR] Weather requesting location permission.\n");
            [self.locationManager requestWhenInUseAuthorization];
            return;
        }
        if (status == kCLAuthorizationStatusDenied || status == kCLAuthorizationStatusRestricted) {
            log_user("[NICEBAR] Weather failed: location authorization status=%d.\n", (int)status);
            [self finishWithOK:NO text:@"Loc denied" temp:nil code:nil fetched:NO];
            return;
        }

        CLLocation *cached = self.locationManager.location;
        if (!force && cached && fabs([cached.timestamp timeIntervalSinceNow]) < 900.0) {
            log_user("[NICEBAR] Weather using recent location fix age=%.0fs.\n",
                     fabs([cached.timestamp timeIntervalSinceNow]));
            [self fetchWeatherForLocation:cached];
            return;
        }

        self.locationRequestInFlight = YES;
        log_user("[NICEBAR] Weather requesting location fix.\n");
        [self.locationManager requestLocation];
    });
}

- (void)locationManagerDidChangeAuthorization:(CLLocationManager *)manager
{
    (void)manager;
    [self refreshWeatherForce:YES useCelsius:self.requestUsesCelsius completion:nil];
}

- (void)locationManager:(CLLocationManager *)manager didChangeAuthorizationStatus:(CLAuthorizationStatus)status
{
    (void)manager;
    (void)status;
    [self refreshWeatherForce:YES useCelsius:self.requestUsesCelsius completion:nil];
}

- (void)locationManager:(CLLocationManager *)manager didFailWithError:(NSError *)error
{
    (void)manager;
    printf("[NICEBAR] weather location failed: %s\n", error.localizedDescription.UTF8String ?: "unknown");
    log_user("[NICEBAR] Weather location failed: %s.\n", error.localizedDescription.UTF8String ?: "unknown");
    self.locationRequestInFlight = NO;
    [self finishWithOK:NO text:@"Weather --" temp:nil code:nil fetched:NO];
}

- (void)locationManager:(CLLocationManager *)manager didUpdateLocations:(NSArray<CLLocation *> *)locations
{
    (void)manager;
    self.locationRequestInFlight = NO;
    CLLocation *location = locations.lastObject;
    if (!location) {
        [self finishWithOK:NO text:@"Weather --" temp:nil code:nil fetched:NO];
        return;
    }
    [self fetchWeatherForLocation:location];
}

- (void)fetchWeatherForLocation:(CLLocation *)location
{
    if (self.weatherFetchInFlight) return;
    self.weatherFetchInFlight = YES;

    NSString *unit = self.requestUsesCelsius ? @"celsius" : @"fahrenheit";
    // ~11 km precision is enough to debug; the log is shareable/uploadable.
    log_user("[NICEBAR] Weather fetching lat=%.1f lon=%.1f unit=%s.\n",
             location.coordinate.latitude,
             location.coordinate.longitude,
             unit.UTF8String);
    NSString *urlString = [NSString stringWithFormat:
        @"https://api.open-meteo.com/v1/forecast?latitude=%.5f&longitude=%.5f&current=temperature_2m,weather_code&temperature_unit=%@&timezone=auto",
        location.coordinate.latitude,
        location.coordinate.longitude,
        unit];
    NSURL *url = [NSURL URLWithString:urlString];
    if (!url) {
        self.weatherFetchInFlight = NO;
        [self finishWithOK:NO text:@"Weather --" temp:nil code:nil fetched:NO];
        return;
    }

    // Bounded: weatherFetchInFlight blocks further fetches until this
    // completes, and the shared session's default timeout is 60 s.
    NSURLRequest *request = [NSURLRequest requestWithURL:url
                                             cachePolicy:NSURLRequestUseProtocolCachePolicy
                                         timeoutInterval:15.0];
    [[[NSURLSession sharedSession] dataTaskWithRequest:request
                                     completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        (void)response;
        dispatch_async(dispatch_get_main_queue(), ^{
            self.weatherFetchInFlight = NO;
            if (error || data.length == 0) {
                printf("[NICEBAR] weather fetch failed: %s\n", error.localizedDescription.UTF8String ?: "no data");
                log_user("[NICEBAR] Weather fetch failed: %s.\n", error.localizedDescription.UTF8String ?: "no data");
                [self finishWithOK:NO text:@"Weather --" temp:nil code:nil fetched:NO];
                return;
            }
            NSDictionary *json = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
            NSDictionary *current = [json isKindOfClass:NSDictionary.class] ? json[@"current"] : nil;
            NSNumber *temp = [current isKindOfClass:NSDictionary.class] ? current[@"temperature_2m"] : nil;
            NSNumber *code = [current isKindOfClass:NSDictionary.class] ? current[@"weather_code"] : nil;
            if (![temp isKindOfClass:NSNumber.class] || ![code isKindOfClass:NSNumber.class]) {
                log_user("[NICEBAR] Weather fetch returned invalid response.\n");
                [self finishWithOK:NO text:@"Weather --" temp:nil code:nil fetched:NO];
                return;
            }
            NSString *summary = CyanideNiceBarWeatherSummary(code.integerValue, NO);
            NSString *text = [NSString stringWithFormat:@"%@ %.0f°", summary, temp.doubleValue];
            log_user("[NICEBAR] Weather fetched %s temp=%.1f code=%ld.\n",
                     text.UTF8String,
                     temp.doubleValue,
                     (long)code.integerValue);
            [self finishWithOK:YES text:text temp:temp code:code fetched:YES];
        });
    }] resume];
}

- (void)finishWithOK:(BOOL)ok
                text:(NSString *)text
                temp:(NSNumber *)temp
                code:(NSNumber *)code
             fetched:(BOOL)fetched
{
    NSString *resolved = text.length ? text : @"Weather --";
    NSArray<CyanideNiceBarWeatherCompletion> *callbacks = [self.pendingCompletions copy];
    [self.pendingCompletions removeAllObjects];
    for (CyanideNiceBarWeatherCompletion callback in callbacks) {
        callback(ok, resolved, temp, code, fetched);
    }
}

@end
