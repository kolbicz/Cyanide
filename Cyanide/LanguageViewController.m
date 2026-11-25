//
//  LanguageViewController.m
//  Cyanide
//

#import "LanguageViewController.h"
#import "Localization/CyanideLanguage.h"

@implementation LanguageViewController

- (void)viewDidLoad
{
    [super viewDidLoad];
    self.title = CyanideLocalized(@"Language");
    self.tableView.backgroundColor = UIColor.systemGroupedBackgroundColor;
    self.tableView.rowHeight = 48.0;
    [self.tableView registerClass:UITableViewCell.class
           forCellReuseIdentifier:@"language"];
}

- (NSArray<NSString *> *)languages
{
    return CyanideLanguageSupportedCodes();
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section
{
    return 1 + (NSInteger)self.languages.count;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath
{
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"language"
                                                            forIndexPath:indexPath];
    cell.accessoryType = UITableViewCellAccessoryNone;
    cell.detailTextLabel.text = nil;
    cell.selectionStyle = UITableViewCellSelectionStyleDefault;

    NSString *stored = [[NSUserDefaults standardUserDefaults]
                        stringForKey:CyanideLanguagePreferenceKey];
    if (indexPath.row == 0) {
        cell.textLabel.text = CyanideLocalized(@"Follow System");
        cell.detailTextLabel.text = CyanideLanguageNativeName(CyanideLanguageSystemCode());
        if (!stored.length) cell.accessoryType = UITableViewCellAccessoryCheckmark;
    } else {
        NSString *code = self.languages[indexPath.row - 1];
        cell.textLabel.text = CyanideLanguageNativeName(code);
        if ([stored isEqualToString:code]) cell.accessoryType = UITableViewCellAccessoryCheckmark;
    }
    cell.textLabel.font = [UIFont systemFontOfSize:17.0];
    cell.textLabel.textColor = UIColor.labelColor;
    cell.detailTextLabel.textColor = UIColor.secondaryLabelColor;
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath
{
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    NSString *code = nil;
    if (indexPath.row > 0) code = self.languages[indexPath.row - 1];

    CyanideLanguageSetCode(code);
    [self.tableView reloadData];

    UIAlertController *notice = [UIAlertController
        alertControllerWithTitle:@"Language changed"
                         message:@"Restart Cyanide to apply the new language."
                  preferredStyle:UIAlertControllerStyleAlert];
    __weak typeof(self) weakSelf = self;
    [notice addAction:[UIAlertAction actionWithTitle:@"OK"
                                                style:UIAlertActionStyleDefault
                                              handler:^(UIAlertAction *_) {
        [weakSelf.navigationController popViewControllerAnimated:YES];
    }]];
    [self presentViewController:notice animated:YES completion:nil];
}

@end
