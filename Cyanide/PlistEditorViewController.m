//
//  PlistEditorViewController.m
//  Cyanide
//

#import "PlistEditorViewController.h"
#import "FileBrowserViewController.h"
#import "installer/MainTabBarController.h"

#pragma mark - Types

typedef NS_ENUM(NSInteger, PLType) {
    PLTypeDictionary, PLTypeArray, PLTypeString, PLTypeInteger,
    PLTypeReal, PLTypeBoolean, PLTypeDate, PLTypeData,
};

static NSArray<NSString *> *pl_type_names(void)
{
    return @[ @"Dictionary", @"Array", @"String", @"Integer", @"Real", @"Boolean", @"Date", @"Data" ];
}

static PLType pl_type_of(id v)
{
    if ([v isKindOfClass:NSDictionary.class]) return PLTypeDictionary;
    if ([v isKindOfClass:NSArray.class]) return PLTypeArray;
    if ([v isKindOfClass:NSString.class]) return PLTypeString;
    if ([v isKindOfClass:NSDate.class]) return PLTypeDate;
    if ([v isKindOfClass:NSData.class]) return PLTypeData;
    if ([v isKindOfClass:NSNumber.class]) {
        if (CFGetTypeID((__bridge CFTypeRef)v) == CFBooleanGetTypeID()) return PLTypeBoolean;
        return CFNumberIsFloatType((__bridge CFNumberRef)v) ? PLTypeReal : PLTypeInteger;
    }
    return PLTypeString;
}

static BOOL pl_is_container(id v)
{
    PLType t = pl_type_of(v);
    return t == PLTypeDictionary || t == PLTypeArray;
}

static NSString *pl_hex(NSData *d, NSUInteger max)
{
    NSUInteger n = MIN(d.length, max);
    const uint8_t *b = d.bytes;
    NSMutableString *s = [NSMutableString stringWithCapacity:n * 3];
    for (NSUInteger i = 0; i < n; i++) [s appendFormat:i ? @" %02x" : @"%02x", b[i]];
    if (d.length > n) [s appendString:@" …"];
    return s;
}

static NSData *pl_data_from_hex(NSString *hex)
{
    NSString *clean = [[hex componentsSeparatedByCharactersInSet:
                        [NSCharacterSet characterSetWithCharactersInString:@" \n\t<>"]] componentsJoinedByString:@""];
    if (clean.length % 2) return nil;
    NSMutableData *d = [NSMutableData dataWithCapacity:clean.length / 2];
    for (NSUInteger i = 0; i < clean.length; i += 2) {
        unsigned int byte;
        NSScanner *sc = [NSScanner scannerWithString:[clean substringWithRange:NSMakeRange(i, 2)]];
        if (![sc scanHexInt:&byte] || !sc.isAtEnd) return nil;
        uint8_t b = (uint8_t)byte;
        [d appendBytes:&b length:1];
    }
    return d;
}

static NSDateFormatter *pl_date_formatter(void)
{
    static NSDateFormatter *f;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        f = [NSDateFormatter new];
        f.dateStyle = NSDateFormatterMediumStyle;
        f.timeStyle = NSDateFormatterMediumStyle;
    });
    return f;
}

static NSString *pl_summary(id v)
{
    switch (pl_type_of(v)) {
        case PLTypeDictionary:
        case PLTypeArray: {
            NSUInteger n = [(NSArray *)v count];
            return [NSString stringWithFormat:@"%lu item%@", (unsigned long)n, n == 1 ? @"" : @"s"];
        }
        case PLTypeString: {
            NSString *s = [(NSString *)v stringByReplacingOccurrencesOfString:@"\n" withString:@" "];
            return s.length > 80 ? [[s substringToIndex:80] stringByAppendingString:@"…"] : s;
        }
        case PLTypeInteger: return [(NSNumber *)v stringValue];
        case PLTypeReal:    return [NSString stringWithFormat:@"%.17g", [(NSNumber *)v doubleValue]];
        case PLTypeBoolean: return [(NSNumber *)v boolValue] ? @"YES" : @"NO";
        case PLTypeDate:    return [pl_date_formatter() stringFromDate:v];
        case PLTypeData: {
            NSData *d = v;
            return [NSString stringWithFormat:@"%lu bytes  %@", (unsigned long)d.length, pl_hex(d, 12)];
        }
    }
    return @"";
}

static id pl_default_value(PLType t)
{
    switch (t) {
        case PLTypeDictionary: return [NSMutableDictionary dictionary];
        case PLTypeArray:      return [NSMutableArray array];
        case PLTypeString:     return @"";
        case PLTypeInteger:    return @0;
        case PLTypeReal:       return @0.0;
        case PLTypeBoolean:    return @NO;
        case PLTypeDate:       return [NSDate date];
        case PLTypeData:       return [NSData data];
    }
    return @"";
}

// Best-effort conversion when the type of a value is changed.
static id pl_convert(id v, PLType to)
{
    PLType from = pl_type_of(v);
    if (from == to) return v;
    NSString *asString = [v isKindOfClass:NSString.class] ? v
                       : [v isKindOfClass:NSNumber.class] ? [(NSNumber *)v stringValue] : nil;
    switch (to) {
        case PLTypeString:
            if ([v isKindOfClass:NSNumber.class]) return from == PLTypeBoolean ? ([v boolValue] ? @"YES" : @"NO") : asString;
            if (from == PLTypeDate) return [pl_date_formatter() stringFromDate:v];
            break;
        case PLTypeInteger: if (asString) return @((long long)asString.longLongValue); break;
        case PLTypeReal:    if (asString) return @(asString.doubleValue); break;
        case PLTypeBoolean:
            if ([v isKindOfClass:NSNumber.class]) return @([v boolValue]);
            if (asString) return @([asString boolValue]);
            break;
        case PLTypeData:
            if (from == PLTypeString) return [(NSString *)v dataUsingEncoding:NSUTF8StringEncoding] ?: [NSData data];
            break;
        default: break;
    }
    return pl_default_value(to);
}

#pragma mark - Document

// One loaded file, shared by every level of the editor.
// Larger files are left to the text/hex viewer: parsing and showing an
// arbitrarily large plist on the device isn't bounded.
static const NSUInteger kPLMaxBytes = 10 * 1024 * 1024;
static const NSUInteger kPLMaxDataEditBytes = 64 * 1024;

@interface PLDocument : NSObject
@property (nonatomic, copy) NSString *path;
@property (nonatomic, strong) id root;
@property (nonatomic, assign) NSPropertyListFormat format;
@property (nonatomic, assign) BOOL dirty;
@property (nonatomic, assign) BOOL readOnly;          // e.g. read through root
@property (nonatomic, strong) NSData *original;       // bytes as loaded, for restore on a failed save
@property (nonatomic, assign) FBFileIdentity identity;
@end

@implementation PLDocument

- (BOOL)parseData:(NSData *)data error:(NSString **)message
{
    NSPropertyListFormat fmt = 0;
    NSError *err = nil;
    id root = [NSPropertyListSerialization propertyListWithData:data
                                                        options:NSPropertyListMutableContainers
                                                         format:&fmt
                                                          error:&err];
    if (!root) { if (message) *message = err.localizedDescription ?: @"Not a property list."; return NO; }
    self.root = root;
    self.format = fmt;
    self.original = data;
    self.dirty = NO;
    return YES;
}

// Regular files up to kPLMaxBytes only. Identity comes from the descriptor
// actually read, and a read error fails the load: an errored partial read
// must never become an editable document (or the restore source of a save).
// Any thread.
- (BOOL)loadWithError:(NSString **)message
{
    if (self.readOnly && !self.original) { if (message) *message = @"Nothing to reload."; return NO; }
    if (self.readOnly) return [self parseData:self.original error:message];
    int fd = filebrowser_open_regular(self.path);
    if (fd < 0) { if (message) *message = @"The file could not be read."; return NO; }
    FBFileIdentity ident = filebrowser_identity_fd(fd);
    BOOL tooBig = NO;
    int rerr = 0;
    NSData *data = filebrowser_read_fd(fd, kPLMaxBytes, &tooBig, &rerr);
    close(fd);
    if (!data) {
        if (message) *message = [NSString stringWithFormat:@"Reading the file failed: %s.", strerror(rerr)];
        return NO;
    }
    if (tooBig) { if (message) *message = @"The plist is larger than 10 MB."; return NO; }
    if (![self parseData:data error:message]) return NO;
    self.identity = ident;
    return YES;
}

// The bytes a save would write (main thread: reads the live model).
- (NSData *)serializedDataWithError:(NSString **)message
{
    NSError *err = nil;
    NSPropertyListFormat fmt = self.format == NSPropertyListOpenStepFormat ? NSPropertyListXMLFormat_v1_0 : self.format;
    NSData *data = [NSPropertyListSerialization dataWithPropertyList:self.root format:fmt options:0 error:&err];
    if (!data && message) *message = err.localizedDescription ?: @"The plist could not be serialized.";
    return data;
}

@end

#pragma mark - Value editor (String / Number / Date / Data)

@interface PLValueViewController : UIViewController
@property (nonatomic, strong) id value;
@property (nonatomic, assign) BOOL editable;
@property (nonatomic, copy) void (^onSave)(id newValue);
@end

@interface PLValueViewController ()
@property (nonatomic, strong) UITextView *textView;
@property (nonatomic, strong) UIDatePicker *datePicker;
@end

@implementation PLValueViewController

- (void)viewDidLoad
{
    [super viewDidLoad];
    self.view.backgroundColor = UIColor.systemBackgroundColor;
    self.navigationItem.largeTitleDisplayMode = UINavigationItemLargeTitleDisplayModeNever;
    PLType t = pl_type_of(self.value);
    UILayoutGuide *g = self.view.safeAreaLayoutGuide;
    // Large Data: show (and allow editing of) at most 64 KB as hex. Building
    // and editing a multi-MB hex string on the main thread isn't usable.
    BOOL bigData = t == PLTypeData && [(NSData *)self.value length] > kPLMaxDataEditBytes;
    if (bigData) self.editable = NO;

    if (t == PLTypeDate) {
        self.datePicker = [UIDatePicker new];
        self.datePicker.datePickerMode = UIDatePickerModeDateAndTime;
        self.datePicker.preferredDatePickerStyle = UIDatePickerStyleInline;
        self.datePicker.date = self.value;
        self.datePicker.enabled = self.editable;
        self.datePicker.translatesAutoresizingMaskIntoConstraints = NO;
        [self.view addSubview:self.datePicker];
        [NSLayoutConstraint activateConstraints:@[
            [self.datePicker.topAnchor constraintEqualToAnchor:g.topAnchor constant:8],
            [self.datePicker.leadingAnchor constraintEqualToAnchor:g.leadingAnchor constant:8],
            [self.datePicker.trailingAnchor constraintEqualToAnchor:g.trailingAnchor constant:-8],
        ]];
    } else {
        self.textView = [UITextView new];
        self.textView.editable = self.editable;
        self.textView.font = t == PLTypeString ? [UIFont systemFontOfSize:16]
                                               : [UIFont monospacedSystemFontOfSize:15 weight:UIFontWeightRegular];
        self.textView.autocapitalizationType = UITextAutocapitalizationTypeNone;
        self.textView.autocorrectionType = UITextAutocorrectionTypeNo;
        self.textView.smartQuotesType = UITextSmartQuotesTypeNo;
        self.textView.smartDashesType = UITextSmartDashesTypeNo;
        if (t == PLTypeInteger || t == PLTypeReal) self.textView.keyboardType = UIKeyboardTypeNumbersAndPunctuation;
        self.textView.text = t == PLTypeData
                           ? (bigData ? [NSString stringWithFormat:@"%@\n\n… first %lu of %lu bytes shown; too large to edit here.",
                                         pl_hex(self.value, kPLMaxDataEditBytes),
                                         (unsigned long)kPLMaxDataEditBytes, (unsigned long)[(NSData *)self.value length]]
                                      : pl_hex(self.value, NSUIntegerMax))
                           : t == PLTypeString ? self.value : pl_summary(self.value);
        self.textView.translatesAutoresizingMaskIntoConstraints = NO;
        [self.view addSubview:self.textView];
        [NSLayoutConstraint activateConstraints:@[
            [self.textView.topAnchor constraintEqualToAnchor:g.topAnchor],
            [self.textView.bottomAnchor constraintEqualToAnchor:self.view.keyboardLayoutGuide.topAnchor],
            [self.textView.leadingAnchor constraintEqualToAnchor:g.leadingAnchor constant:8],
            [self.textView.trailingAnchor constraintEqualToAnchor:g.trailingAnchor constant:-8],
        ]];
        if (self.editable) [self.textView becomeFirstResponder];
    }
    if (self.editable) {
        self.navigationItem.rightBarButtonItem =
            [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemDone
                                                          target:self action:@selector(done)];
    }
}

- (void)done
{
    PLType t = pl_type_of(self.value);
    NSString *text = self.textView.text ?: @"";
    NSString *trimmed = [text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    id result = nil;
    NSString *error = nil;
    switch (t) {
        case PLTypeDate:   result = self.datePicker.date; break;
        case PLTypeString: result = text; break;
        case PLTypeData:
            result = pl_data_from_hex(text);
            if (!result) error = @"Enter the bytes as hex pairs, for example \"0a ff 10\".";
            break;
        case PLTypeInteger: {
            NSScanner *sc = [NSScanner scannerWithString:trimmed];
            long long v;
            if ([sc scanLongLong:&v] && sc.isAtEnd) result = @(v);
            else error = @"Enter a whole number.";
            break;
        }
        case PLTypeReal: {
            NSScanner *sc = [NSScanner scannerWithString:trimmed];
            double v;
            if ([sc scanDouble:&v] && sc.isAtEnd) result = @(v);
            else error = @"Enter a number, for example 1.5.";
            break;
        }
        default: break;
    }
    if (error) {
        UIAlertController *ac = [UIAlertController alertControllerWithTitle:@"Invalid Value"
                                                                    message:error
                                                             preferredStyle:UIAlertControllerStyleAlert];
        [ac addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
        [self presentViewController:ac animated:YES completion:nil];
        return;
    }
    if (result && self.onSave) self.onSave(result);
    [self.navigationController popViewControllerAnimated:YES];
}

@end

#pragma mark - Container editor

@interface PlistEditorViewController () <UISearchResultsUpdating>
@property (nonatomic, strong) PLDocument *doc;
@property (nonatomic, strong) id container;            // NSMutableDictionary / NSMutableArray
@property (nonatomic, assign) BOOL isRoot;
@property (nonatomic, strong) NSArray *rows;           // dict keys (sorted) or array indexes
@property (nonatomic, copy) NSString *filter;
@property (nonatomic, assign) BOOL saving;   // save/revert running off-main
@end

@implementation PlistEditorViewController

+ (id)documentForFileAtPath:(NSString *)path
{
    PLDocument *doc = [PLDocument new];
    doc.path = path;
    // A root that is a plain value (rare) is left to the text viewer.
    if (![doc loadWithError:NULL] || !pl_is_container(doc.root)) return nil;
    return doc;
}

+ (id)readOnlyDocumentForData:(NSData *)data path:(NSString *)path
{
    if (data.length > kPLMaxBytes) return nil;
    PLDocument *doc = [PLDocument new];
    doc.path = path;
    doc.readOnly = YES;
    if (![doc parseData:data error:NULL] || !pl_is_container(doc.root)) return nil;
    return doc;
}

+ (instancetype)editorWithDocument:(id)document
{
    PLDocument *doc = document;
    if (![doc isKindOfClass:PLDocument.class]) return nil;
    PlistEditorViewController *vc = [[self alloc] initWithDocument:doc container:doc.root];
    vc.isRoot = YES;
    vc.title = doc.path.lastPathComponent;
    return vc;
}

- (instancetype)initWithDocument:(PLDocument *)doc container:(id)container
{
    if ((self = [super initWithStyle:UITableViewStylePlain])) {
        _doc = doc;
        _container = container;
        _filter = @"";
    }
    return self;
}

- (BOOL)isDict { return [self.container isKindOfClass:NSDictionary.class]; }
- (BOOL)writable { return filebrowser_write_enabled() && !self.doc.readOnly && pl_is_container(self.container); }

- (void)viewDidLoad
{
    [super viewDidLoad];
    self.navigationItem.largeTitleDisplayMode = UINavigationItemLargeTitleDisplayModeAlways;
    if (self.isRoot) {
        NSString *fmt = self.doc.format == NSPropertyListBinaryFormat_v1_0 ? @"binary"
                      : self.doc.format == NSPropertyListXMLFormat_v1_0 ? @"XML" : @"OpenStep";
        self.navigationItem.prompt = [NSString stringWithFormat:@"%@ (%@ plist%@)", self.doc.path, fmt,
                                      self.doc.readOnly ? @", read as root" : @""];
    }
    UISearchController *sc = [[UISearchController alloc] initWithSearchResultsController:nil];
    sc.searchResultsUpdater = self;
    sc.obscuresBackgroundDuringPresentation = NO;
    sc.searchBar.placeholder = @"Filter keys and values";
    self.navigationItem.searchController = sc;
    self.navigationItem.hidesSearchBarWhenScrolling = YES;
    self.definesPresentationContext = YES;
}

- (void)viewWillAppear:(BOOL)animated
{
    [super viewWillAppear:animated];
    UITabBarController *tbc = self.tabBarController;
    if ([tbc isKindOfClass:MainTabBarController.class]) [(MainTabBarController *)tbc setPopupBarSuppressed:YES];
    [self reloadRows];
    [self updateBarButtons];
}

- (void)viewWillDisappear:(BOOL)animated
{
    [super viewWillDisappear:animated];
    UITabBarController *tbc = self.tabBarController;
    if ([tbc isKindOfClass:MainTabBarController.class]) [(MainTabBarController *)tbc setPopupBarSuppressed:NO];
}

- (void)reloadRows
{
    NSArray *rows;
    if (self.isDict) {
        rows = [[(NSDictionary *)self.container allKeys] sortedArrayUsingComparator:^NSComparisonResult(id a, id b) {
            return [[a description] localizedStandardCompare:[b description]];
        }];
    } else {
        NSMutableArray *idx = [NSMutableArray array];
        for (NSUInteger i = 0; i < [(NSArray *)self.container count]; i++) [idx addObject:@(i)];
        rows = idx;
    }
    NSString *q = [self.filter stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
    if (q.length) {
        rows = [rows filteredArrayUsingPredicate:[NSPredicate predicateWithBlock:^BOOL(id row, NSDictionary *b) {
            NSString *label = [self labelForRow:row];
            return [label rangeOfString:q options:NSCaseInsensitiveSearch].location != NSNotFound ||
                   [pl_summary([self valueForRow:row]) rangeOfString:q options:NSCaseInsensitiveSearch].location != NSNotFound;
        }]];
    }
    self.rows = rows;
    [self.tableView reloadData];
}

- (id)valueForRow:(id)row
{
    return self.isDict ? self.container[row] : self.container[[row unsignedIntegerValue]];
}

- (NSString *)labelForRow:(id)row
{
    return self.isDict ? [row description] : [NSString stringWithFormat:@"Item %@", row];
}

// Every model mutation goes through here (or checks it first): a value
// editor, menu or switch from before locking must not change the model.
- (BOOL)ensureWritable
{
    if (self.writable && !self.saving) return YES;
    [self showMessage:@"Changes are locked. Unlock them in the File Browser to edit."
                title:@"Not Changed"];
    [self reloadRows];   // e.g. flip a switch back
    return NO;
}

- (void)setValue:(id)value forRow:(id)row
{
    if (![self ensureWritable]) return;
    if (self.isDict) self.container[row] = value;
    else self.container[[row unsignedIntegerValue]] = value;
    [self markDirty];
}

- (void)markDirty
{
    self.doc.dirty = YES;
    [self reloadRows];
    [self updateBarButtons];
}

#pragma mark Bar buttons, save, revert

- (void)updateBarButtons
{
    NSMutableArray *items = [NSMutableArray array];
    // Save only while changes are unlocked; edits made before locking stay
    // pending (Revert discards them, unlocking again allows Save).
    if (self.doc.dirty && filebrowser_write_enabled() && !self.doc.readOnly) {
        [items addObject:[[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemSave
                                                                       target:self action:@selector(save)]];
    }
    if (self.writable) {
        __weak typeof(self) weakSelf = self;
        NSMutableArray<UIMenuElement *> *adds = [NSMutableArray array];
        NSArray<NSString *> *names = pl_type_names();
        for (NSInteger t = 0; t < (NSInteger)names.count; t++) {
            [adds addObject:[UIAction actionWithTitle:names[t] image:nil identifier:nil handler:^(UIAction *a) {
                [weakSelf addItemOfType:(PLType)t];
            }]];
        }
        NSMutableArray<UIMenuElement *> *menu = [NSMutableArray arrayWithObject:
            [UIMenu menuWithTitle:self.isDict ? @"Add Key" : @"Add Item" image:nil identifier:nil
                          options:UIMenuOptionsDisplayInline children:adds]];
        if (!self.isDict && [(NSArray *)self.container count] > 1) {
            [menu addObject:[UIAction actionWithTitle:self.tableView.editing ? @"Done Reordering" : @"Reorder Items"
                                                image:[UIImage systemImageNamed:@"arrow.up.arrow.down"]
                                           identifier:nil handler:^(UIAction *a) {
                [weakSelf.tableView setEditing:!weakSelf.tableView.editing animated:YES];
                [weakSelf updateBarButtons];
            }]];
        }
        [items addObject:[[UIBarButtonItem alloc] initWithImage:[UIImage systemImageNamed:@"plus"]
                                                           menu:[UIMenu menuWithChildren:menu]]];
    }
    self.navigationItem.rightBarButtonItems = items;
    // At the root, unsaved changes need an explicit Save or Revert: leaving
    // would otherwise silently drop them.
    if (self.isRoot) {
        self.navigationItem.hidesBackButton = self.doc.dirty;
        self.navigationItem.leftBarButtonItem = self.doc.dirty
            ? [[UIBarButtonItem alloc] initWithTitle:@"Revert" style:UIBarButtonItemStylePlain
                                              target:self action:@selector(confirmRevert)]
            : nil;
    }
}

- (void)save { [self saveForcing:NO]; }

// Conflict-checked, backed-up save (filebrowser_save) with the file I/O
// off-main; the editor is frozen meanwhile so the model can't change under it.
- (void)saveForcing:(BOOL)force
{
    if (self.saving) return;
    if (self.doc.readOnly || !filebrowser_write_enabled()) {
        [self showMessage:@"Changes are locked." title:@"Not Saved"];
        return;
    }
    NSString *message = nil;
    NSData *data = [self.doc serializedDataWithError:&message];
    if (!data) { [self showMessage:message title:@"Not Saved"]; return; }
    PLDocument *doc = self.doc;
    NSString *path = doc.path;
    FBFileIdentity expected = doc.identity;
    NSData *loaded = doc.original;
    [self setBusy:YES];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        FBFileIdentity newIdent = {0};
        NSString *msg = nil;
        FBSaveResult r = filebrowser_save(path, data, expected, loaded, force, &newIdent, &msg);
        dispatch_async(dispatch_get_main_queue(), ^{
            [self setBusy:NO];
            if (r == FBSaveOK) {
                doc.original = data;
                doc.identity = newIdent;
                doc.dirty = NO;
                [self updateBarButtons];
                return;
            }
            if (r == FBSaveConflict) {
                UIAlertController *ac = [UIAlertController alertControllerWithTitle:@"File Changed"
                                                                            message:@"The file was changed or replaced since you opened it. "
                                                                                    @"Overwrite it with your version, or Revert to load the current one?"
                                                                     preferredStyle:UIAlertControllerStyleAlert];
                [ac addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
                [ac addAction:[UIAlertAction actionWithTitle:@"Overwrite" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *a) {
                    [self saveForcing:YES];
                }]];
                [self presentViewController:ac animated:YES completion:nil];
                return;
            }
            [self showMessage:msg ?: @"The file could not be written." title:@"Not Saved"];
        });
    });
}

- (void)showMessage:(NSString *)message title:(NSString *)title
{
    UIAlertController *ac = [UIAlertController alertControllerWithTitle:title message:message
                                                         preferredStyle:UIAlertControllerStyleAlert];
    [ac addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:ac animated:YES completion:nil];
}

// Freezes the editor while a save/revert runs off-main.
- (void)setBusy:(BOOL)busy
{
    self.saving = busy;
    self.tableView.userInteractionEnabled = !busy;
    [self updateBarButtons];
    for (UIBarButtonItem *item in self.navigationItem.rightBarButtonItems) item.enabled = !busy;
    self.navigationItem.leftBarButtonItem.enabled = !busy;
    if (busy) self.navigationItem.hidesBackButton = YES;
}

- (void)confirmRevert
{
    UIAlertController *ac = [UIAlertController alertControllerWithTitle:@"Discard Changes?"
                                                                message:@"The file is reloaded as it is on disk."
                                                         preferredStyle:UIAlertControllerStyleAlert];
    [ac addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    [ac addAction:[UIAlertAction actionWithTitle:@"Discard" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *a) {
        // Reload into a fresh document off-main; swap it in only if it worked.
        PLDocument *doc = self.doc;
        PLDocument *fresh = [PLDocument new];
        fresh.path = doc.path;
        fresh.readOnly = doc.readOnly;
        fresh.original = doc.readOnly ? doc.original : nil;
        [self setBusy:YES];
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
            NSString *message = nil;
            BOOL ok = [fresh loadWithError:&message];
            dispatch_async(dispatch_get_main_queue(), ^{
                [self setBusy:NO];
                if (!ok) {
                    // Keep the edits rather than pretend they were discarded.
                    [self showMessage:[NSString stringWithFormat:@"%@ Your changes are kept.", message ?: @""]
                                title:@"Couldn't Revert"];
                    return;
                }
                doc.root = fresh.root;
                doc.format = fresh.format;
                doc.original = fresh.original;
                doc.identity = fresh.identity;
                doc.dirty = NO;
                self.container = doc.root;
                [self.tableView setEditing:NO animated:NO];
                [self reloadRows];
                [self updateBarButtons];
            });
        });
    }]];
    [self presentViewController:ac animated:YES completion:nil];
}

#pragma mark Add, delete, rename, retype

- (void)promptForKey:(NSString *)title initial:(NSString *)initial then:(void (^)(NSString *key))then
{
    UIAlertController *ac = [UIAlertController alertControllerWithTitle:title message:nil
                                                         preferredStyle:UIAlertControllerStyleAlert];
    [ac addTextFieldWithConfigurationHandler:^(UITextField *tf) {
        tf.text = initial;
        tf.placeholder = @"Key";
        tf.autocapitalizationType = UITextAutocapitalizationTypeNone;
        tf.autocorrectionType = UITextAutocorrectionTypeNo;
    }];
    [ac addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    [ac addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
        NSString *key = ac.textFields.firstObject.text ?: @"";
        if (!key.length) return;
        if (self.container[key] && ![key isEqualToString:initial]) {
            UIAlertController *dup = [UIAlertController alertControllerWithTitle:@"Key Exists"
                                                                         message:[NSString stringWithFormat:@"\"%@\" is already in this dictionary.", key]
                                                                  preferredStyle:UIAlertControllerStyleAlert];
            [dup addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
            [self presentViewController:dup animated:YES completion:nil];
            return;
        }
        then(key);
    }]];
    [self presentViewController:ac animated:YES completion:nil];
}

- (void)addItemOfType:(PLType)t
{
    if (![self ensureWritable]) return;
    id value = pl_default_value(t);
    if (self.isDict) {
        [self promptForKey:@"New Key" initial:@"" then:^(NSString *key) {
            if (![self ensureWritable]) return;
            self.container[key] = value;
            [self markDirty];
        }];
    } else {
        [(NSMutableArray *)self.container addObject:value];
        [self markDirty];
    }
}

- (void)deleteRow:(id)row
{
    if (![self ensureWritable]) return;
    if (self.isDict) [(NSMutableDictionary *)self.container removeObjectForKey:row];
    else [(NSMutableArray *)self.container removeObjectAtIndex:[row unsignedIntegerValue]];
    [self markDirty];
}

- (void)renameRow:(id)row
{
    if (!self.isDict || ![self ensureWritable]) return;
    [self promptForKey:@"Rename Key" initial:[row description] then:^(NSString *key) {
        if ([key isEqualToString:[row description]] || ![self ensureWritable]) return;
        id v = self.container[row];
        [(NSMutableDictionary *)self.container removeObjectForKey:row];
        self.container[key] = v;
        [self markDirty];
    }];
}

- (UIMenu *)typeMenuForRow:(id)row
{
    PLType current = pl_type_of([self valueForRow:row]);
    NSMutableArray *actions = [NSMutableArray array];
    NSArray<NSString *> *names = pl_type_names();
    for (NSInteger t = 0; t < (NSInteger)names.count; t++) {
        UIAction *a = [UIAction actionWithTitle:names[t] image:nil identifier:nil handler:^(UIAction *x) {
            if ((PLType)t == current) return;
            [self setValue:pl_convert([self valueForRow:row], (PLType)t) forRow:row];
        }];
        if ((PLType)t == current) a.state = UIMenuElementStateOn;
        [actions addObject:a];
    }
    return [UIMenu menuWithTitle:@"Change Type" image:[UIImage systemImageNamed:@"arrow.triangle.2.circlepath"]
                      identifier:nil options:0 children:actions];
}

#pragma mark Table

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section
{
    return self.rows.count ? (NSInteger)self.rows.count : 1;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath
{
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"pl"];
    if (!cell) cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"pl"];
    cell.detailTextLabel.textColor = UIColor.secondaryLabelColor;
    cell.detailTextLabel.font = [UIFont systemFontOfSize:13];
    cell.accessoryView = nil;

    if (!self.rows.count) {
        cell.textLabel.text = self.filter.length ? @"No matches." : @"Empty.";
        cell.textLabel.textColor = UIColor.secondaryLabelColor;
        cell.detailTextLabel.text = nil;
        cell.accessoryType = UITableViewCellAccessoryNone;
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
        return cell;
    }

    id row = self.rows[indexPath.row];
    id value = [self valueForRow:row];
    PLType t = pl_type_of(value);
    cell.textLabel.text = [self labelForRow:row];
    cell.textLabel.textColor = UIColor.labelColor;
    cell.detailTextLabel.text = [NSString stringWithFormat:@"%@ · %@", pl_type_names()[t], pl_summary(value)];
    cell.selectionStyle = UITableViewCellSelectionStyleDefault;
    cell.accessoryType = pl_is_container(value) ? UITableViewCellAccessoryDisclosureIndicator
                                                : UITableViewCellAccessoryNone;
    if (t == PLTypeBoolean) {
        // Booleans are switched right in the row.
        UISwitch *sw = [UISwitch new];
        sw.on = [value boolValue];
        sw.enabled = self.writable;
        sw.tag = indexPath.row;
        [sw addTarget:self action:@selector(boolSwitched:) forControlEvents:UIControlEventValueChanged];
        cell.accessoryView = sw;
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
    }
    return cell;
}

- (void)boolSwitched:(UISwitch *)sw
{
    if (sw.tag >= (NSInteger)self.rows.count) return;
    [self setValue:@(sw.on) forRow:self.rows[sw.tag]];
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath
{
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    if (!self.rows.count) return;
    id row = self.rows[indexPath.row];
    id value = [self valueForRow:row];
    PLType t = pl_type_of(value);
    if (t == PLTypeBoolean) return;
    if (pl_is_container(value)) {
        PlistEditorViewController *child = [[PlistEditorViewController alloc] initWithDocument:self.doc container:value];
        child.title = [self labelForRow:row];
        [self.navigationController pushViewController:child animated:YES];
        return;
    }
    PLValueViewController *vc = [PLValueViewController new];
    vc.title = [self labelForRow:row];
    vc.value = value;
    vc.editable = self.writable;
    __weak typeof(self) weakSelf = self;
    vc.onSave = ^(id newValue) { [weakSelf setValue:newValue forRow:row]; };
    [self.navigationController pushViewController:vc animated:YES];
}

- (UISwipeActionsConfiguration *)tableView:(UITableView *)tableView
    trailingSwipeActionsConfigurationForRowAtIndexPath:(NSIndexPath *)indexPath
{
    if (!self.writable || !self.rows.count) return nil;
    id row = self.rows[indexPath.row];
    UIContextualAction *del = [UIContextualAction contextualActionWithStyle:UIContextualActionStyleDestructive
                                                                      title:@"Delete"
                                                                    handler:^(UIContextualAction *a, UIView *v, void (^done)(BOOL)) {
        [self deleteRow:row];
        done(YES);
    }];
    UISwipeActionsConfiguration *cfg = [UISwipeActionsConfiguration configurationWithActions:@[ del ]];
    cfg.performsFirstActionWithFullSwipe = NO;
    return cfg;
}

- (UIContextMenuConfiguration *)tableView:(UITableView *)tableView
    contextMenuConfigurationForRowAtIndexPath:(NSIndexPath *)indexPath
                                        point:(CGPoint)point
{
    if (!self.rows.count) return nil;
    id row = self.rows[indexPath.row];
    return [UIContextMenuConfiguration configurationWithIdentifier:nil previewProvider:nil
                                                    actionProvider:^UIMenu *(NSArray<UIMenuElement *> *s) {
        NSMutableArray<UIMenuElement *> *items = [NSMutableArray array];
        id value = [self valueForRow:row];
        [items addObject:[UIAction actionWithTitle:@"Copy Value" image:[UIImage systemImageNamed:@"doc.on.doc"]
                                        identifier:nil handler:^(UIAction *a) {
            id v = [self valueForRow:row];
            UIPasteboard.generalPasteboard.string = [v isKindOfClass:NSString.class] ? v : pl_summary(v);
        }]];
        if (self.isDict) {
            [items addObject:[UIAction actionWithTitle:@"Copy Key" image:[UIImage systemImageNamed:@"key"]
                                            identifier:nil handler:^(UIAction *a) {
                UIPasteboard.generalPasteboard.string = [row description];
            }]];
        }
        if (self.writable) {
            NSMutableArray<UIMenuElement *> *edit = [NSMutableArray array];
            if (self.isDict) {
                [edit addObject:[UIAction actionWithTitle:@"Rename Key" image:[UIImage systemImageNamed:@"pencil"]
                                               identifier:nil handler:^(UIAction *a) { [self renameRow:row]; }]];
            }
            [edit addObject:[self typeMenuForRow:row]];
            UIAction *del = [UIAction actionWithTitle:@"Delete" image:[UIImage systemImageNamed:@"trash"]
                                           identifier:nil handler:^(UIAction *a) { [self deleteRow:row]; }];
            del.attributes = UIMenuElementAttributesDestructive;
            [edit addObject:del];
            [items addObject:[UIMenu menuWithTitle:@"" image:nil identifier:nil
                                           options:UIMenuOptionsDisplayInline children:edit]];
        }
        (void)value;
        return [UIMenu menuWithTitle:[self labelForRow:row] children:items];
    }];
}

// Reordering (arrays only, in edit mode).
- (BOOL)tableView:(UITableView *)tableView canMoveRowAtIndexPath:(NSIndexPath *)indexPath
{
    return !self.isDict && self.writable && self.rows.count && !self.filter.length;
}

- (UITableViewCellEditingStyle)tableView:(UITableView *)tableView editingStyleForRowAtIndexPath:(NSIndexPath *)indexPath
{
    return UITableViewCellEditingStyleNone;
}

- (BOOL)tableView:(UITableView *)tableView shouldIndentWhileEditingRowAtIndexPath:(NSIndexPath *)indexPath
{
    return NO;
}

- (void)tableView:(UITableView *)tableView moveRowAtIndexPath:(NSIndexPath *)from toIndexPath:(NSIndexPath *)to
{
    if (!self.writable) {   // the table already moved the row: put it back
        dispatch_async(dispatch_get_main_queue(), ^{ [self reloadRows]; });
        return;
    }
    NSMutableArray *arr = self.container;
    id item = arr[from.row];
    [arr removeObjectAtIndex:from.row];
    [arr insertObject:item atIndex:to.row];
    self.doc.dirty = YES;
    // Labels are indexes: refresh after the move animation settles.
    dispatch_async(dispatch_get_main_queue(), ^{
        [self reloadRows];
        [self updateBarButtons];
    });
}

- (void)updateSearchResultsForSearchController:(UISearchController *)searchController
{
    self.filter = searchController.searchBar.text ?: @"";
    [self reloadRows];
}

@end
