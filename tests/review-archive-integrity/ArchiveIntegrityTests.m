#import <Foundation/Foundation.h>
#import <zlib.h>
#include <stdio.h>
#include <stdlib.h>
#include <sys/stat.h>
#include <unistd.h>

#import "SBLArchiveExtractor.h"

static void require_condition(BOOL condition, NSString *message)
{
    if (condition) return;
    fprintf(stderr, "archive integrity test failed: %s\n", message.UTF8String);
    exit(1);
}

@interface PollCancellationProgress : NSProgress
@property(nonatomic) NSUInteger cancelAtPoll;
@property(nonatomic) NSUInteger pollCount;
@end

@implementation PollCancellationProgress
- (BOOL)isCancelled
{
    self.pollCount += 1;
    return self.cancelAtPoll != 0 && self.pollCount >= self.cancelAtPoll;
}
@end

static void append16(NSMutableData *data, uint16_t value)
{
    uint8_t bytes[] = {(uint8_t)value, (uint8_t)(value >> 8)};
    [data appendBytes:bytes length:sizeof(bytes)];
}

static void append32(NSMutableData *data, uint32_t value)
{
    uint8_t bytes[] = {(uint8_t)value, (uint8_t)(value >> 8),
                       (uint8_t)(value >> 16), (uint8_t)(value >> 24)};
    [data appendBytes:bytes length:sizeof(bytes)];
}

static NSData *raw_deflate_stored_block(NSData *input)
{
    require_condition(input.length <= UINT16_MAX, @"fixture payload is too large");
    NSMutableData *output = [NSMutableData data];
    uint8_t finalStoredBlock = 0x01; // final block, stored (uncompressed) type
    [output appendBytes:&finalStoredBlock length:1];
    append16(output, (uint16_t)input.length);
    append16(output, (uint16_t)~input.length);
    [output appendData:input];
    return output;
}

static NSData *empty_fixed_deflate(void)
{
    const uint8_t bytes[] = {0x03, 0x00}; // final fixed block, no output
    return [NSData dataWithBytes:bytes length:sizeof(bytes)];
}

static NSData *zero_output_deflate_stream(NSUInteger nonFinalBlocks)
{
    NSMutableData *output = [NSMutableData data];
    for (NSUInteger i = 0; i < nonFinalBlocks; i++) {
        uint8_t block = 0x00; // non-final stored block, zero bytes
        [output appendBytes:&block length:1];
        append16(output, 0);
        append16(output, UINT16_MAX);
    }
    uint8_t finalBlock = 0x01; // final stored block, zero bytes
    [output appendBytes:&finalBlock length:1];
    append16(output, 0);
    append16(output, UINT16_MAX);
    return output;
}

static NSDictionary *entry(NSString *name, NSData *data, uint16_t method,
                            uint16_t flags, BOOL descriptorSignature,
                            BOOL corruptPayload)
{
    return @{@"name": name,
             @"data": data,
             @"method": @(method),
             @"flags": @(flags),
             @"descriptorSignature": @(descriptorSignature),
             @"corruptPayload": @(corruptPayload)};
}

static NSDictionary *entry_with_compressed(NSString *name, NSData *data,
                                            uint16_t method, uint16_t flags,
                                            BOOL descriptorSignature,
                                            BOOL corruptPayload, NSData *compressed)
{
    NSMutableDictionary *spec = [entry(name, data, method, flags,
                                        descriptorSignature, corruptPayload) mutableCopy];
    spec[@"compressed"] = compressed;
    return spec;
}

static NSData *make_zip(NSArray<NSDictionary *> *entries)
{
    NSMutableData *zip = [NSMutableData data];
    NSMutableArray<NSDictionary *> *records = [NSMutableArray array];
    for (NSDictionary *spec in entries) {
        NSString *name = spec[@"name"];
        NSData *data = spec[@"data"];
        uint16_t method = [spec[@"method"] unsignedShortValue];
        uint16_t flags = [spec[@"flags"] unsignedShortValue];
        BOOL hasDescriptor = (flags & (1u << 3)) != 0;
        NSData *nameData = [name dataUsingEncoding:NSUTF8StringEncoding];
        NSData *compressed = spec[@"compressed"] ?: (method == 8 ? raw_deflate_stored_block(data) : data);
        uint32_t crc = (uint32_t)crc32(crc32(0L, Z_NULL, 0), data.bytes, (uInt)data.length);
        NSUInteger localOffset = zip.length;
        uint32_t localCRC = hasDescriptor ? 0 : crc;
        uint32_t localCompressedSize = hasDescriptor ? 0 : (uint32_t)compressed.length;
        uint32_t localUncompressedSize = hasDescriptor ? 0 : (uint32_t)data.length;

        append32(zip, 0x04034b50);
        append16(zip, 20);
        append16(zip, flags);
        append16(zip, method);
        append16(zip, 0);
        append16(zip, 0);
        append32(zip, localCRC);
        append32(zip, localCompressedSize);
        append32(zip, localUncompressedSize);
        append16(zip, (uint16_t)nameData.length);
        append16(zip, 0);
        [zip appendData:nameData];
        NSUInteger payloadOffset = zip.length;
        [zip appendData:compressed];
        if ([spec[@"corruptPayload"] boolValue]) {
            require_condition(compressed.length > 0, @"corrupt fixture has no payload");
            NSUInteger byteToCorrupt = method == 8 ? payloadOffset + 5 : payloadOffset;
            ((uint8_t *)zip.mutableBytes)[byteToCorrupt] ^= 0x20;
        }
        if (hasDescriptor) {
            if ([spec[@"descriptorSignature"] boolValue]) append32(zip, 0x08074b50);
            append32(zip, crc);
            append32(zip, (uint32_t)compressed.length);
            append32(zip, (uint32_t)data.length);
        }
        [records addObject:@{ @"nameData": nameData,
                              @"data": data,
                              @"method": @(method),
                              @"flags": @(flags),
                              @"crc": @(crc),
                              @"compressedSize": @(compressed.length),
                              @"localOffset": @(localOffset) }];
    }

    NSUInteger centralOffset = zip.length;
    for (NSDictionary *record in records) {
        NSData *nameData = record[@"nameData"];
        uint16_t method = [record[@"method"] unsignedShortValue];
        uint16_t flags = [record[@"flags"] unsignedShortValue];
        append32(zip, 0x02014b50);
        append16(zip, 20); // version made by
        append16(zip, 20); // version needed
        append16(zip, flags);
        append16(zip, method);
        append16(zip, 0);
        append16(zip, 0);
        append32(zip, [record[@"crc"] unsignedIntValue]);
        append32(zip, [record[@"compressedSize"] unsignedIntValue]);
        append32(zip, (uint32_t)[record[@"data"] length]);
        append16(zip, (uint16_t)nameData.length);
        append16(zip, 0);
        append16(zip, 0);
        append16(zip, 0);
        append16(zip, 0);
        append32(zip, 0);
        append32(zip, [record[@"localOffset"] unsignedIntValue]);
        [zip appendData:nameData];
    }
    NSUInteger centralSize = zip.length - centralOffset;
    append32(zip, 0x06054b50);
    append16(zip, 0);
    append16(zip, 0);
    append16(zip, (uint16_t)records.count);
    append16(zip, (uint16_t)records.count);
    append32(zip, (uint32_t)centralSize);
    append32(zip, (uint32_t)centralOffset);
    append16(zip, 0);
    return zip;
}

static NSString *make_temp_root(void)
{
    char template[] = "/tmp/cyanide-archive-integrity-XXXXXX";
    char *path = mkdtemp(template);
    require_condition(path != NULL, @"could not create temporary fixture directory");
    return [NSString stringWithUTF8String:path];
}

static BOOL filesystem_treats_paths_as_equivalent(NSString *root,
                                                    NSString *first,
                                                    NSString *alias)
{
    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *firstPath = [root stringByAppendingPathComponent:first];
    NSString *aliasPath = [root stringByAppendingPathComponent:alias];
    NSData *probe = [NSData dataWithBytes:"x" length:1];
    require_condition([probe writeToFile:firstPath atomically:YES],
                      @"could not create filesystem alias probe");
    BOOL equivalent = [fm fileExistsAtPath:aliasPath];
    require_condition([fm removeItemAtPath:firstPath error:nil],
                      @"could not remove filesystem alias probe");
    return equivalent;
}

static void write_archive(NSData *archive, NSString *root, NSString *name)
{
    NSString *path = [root stringByAppendingPathComponent:name];
    require_condition([archive writeToFile:path atomically:YES],
                      [NSString stringWithFormat:@"could not write %@", name]);
}

static void expect_success(NSData *archive, NSString *root, NSString *caseName,
                           NSString *entryName, NSData *expected)
{
    NSString *archiveName = [caseName stringByAppendingString:@".zip"];
    NSString *destination = [root stringByAppendingPathComponent:
                              [caseName stringByAppendingString:@"-output"]];
    write_archive(archive, root, archiveName);
    NSError *error = nil;
    BOOL ok = SBLExtractArchiveToDirectory([NSURL fileURLWithPath:
                                            [root stringByAppendingPathComponent:archiveName]],
                                           destination, &error);
    require_condition(ok, [NSString stringWithFormat:@"%@ should extract: %@", caseName,
                            error.localizedDescription]);
    NSData *actual = [NSData dataWithContentsOfFile:
                      [destination stringByAppendingPathComponent:entryName]];
    require_condition([actual isEqualToData:expected],
                      [NSString stringWithFormat:@"%@ output mismatch", caseName]);
}

static void expect_failure(NSData *archive, NSString *root, NSString *caseName,
                           BOOL seedEmptyDestination)
{
    NSString *archiveName = [caseName stringByAppendingString:@".zip"];
    NSString *destination = [root stringByAppendingPathComponent:
                              [caseName stringByAppendingString:@"-output"]];
    write_archive(archive, root, archiveName);
    if (seedEmptyDestination) {
        require_condition([[NSFileManager defaultManager] createDirectoryAtPath:destination
                                                       withIntermediateDirectories:YES
                                                                        attributes:nil
                                                                             error:nil],
                          @"could not seed empty destination");
    }
    NSError *error = nil;
    BOOL ok = SBLExtractArchiveToDirectory([NSURL fileURLWithPath:
                                            [root stringByAppendingPathComponent:archiveName]],
                                           destination, &error);
    require_condition(!ok, [NSString stringWithFormat:@"%@ should be rejected", caseName]);
    BOOL exists = [[NSFileManager defaultManager] fileExistsAtPath:destination];
    require_condition(exists == seedEmptyDestination,
                      [NSString stringWithFormat:@"%@ changed the original destination", caseName]);
    if (exists) require_condition([[NSFileManager defaultManager] contentsOfDirectoryAtPath:destination error:nil].count == 0,
                                 @"failure exposed a partial extraction");
}

static void expect_cancellation(NSData *archive, NSString *root, NSString *caseName,
                                NSUInteger cancelAtPoll, BOOL seedEmptyDestination)
{
    NSString *archiveName = [caseName stringByAppendingString:@".zip"];
    NSString *destination = [root stringByAppendingPathComponent:
                              [caseName stringByAppendingString:@"-output"]];
    write_archive(archive, root, archiveName);
    NSFileManager *fm = [NSFileManager defaultManager];
    if (seedEmptyDestination) {
        require_condition([fm createDirectoryAtPath:destination
                         withIntermediateDirectories:YES
                                          attributes:nil
                                               error:nil],
                          @"could not seed cancellation destination");
    }
    PollCancellationProgress *progress = [[PollCancellationProgress alloc]
                                           initWithParent:nil userInfo:nil];
    progress.cancelAtPoll = cancelAtPoll;
    NSError *error = nil;
    BOOL ok = SBLExtractArchiveToDirectoryWithProgress(
        [NSURL fileURLWithPath:[root stringByAppendingPathComponent:archiveName]],
        destination, progress, &error);
    require_condition(!ok, [NSString stringWithFormat:@"%@ should cancel", caseName]);
    require_condition(progress.pollCount >= cancelAtPoll,
                      [NSString stringWithFormat:@"%@ did not reach its cancellation poll", caseName]);
    BOOL exists = [fm fileExistsAtPath:destination];
    require_condition(exists == seedEmptyDestination,
                      [NSString stringWithFormat:@"%@ changed the destination", caseName]);
    if (exists) {
        require_condition([fm contentsOfDirectoryAtPath:destination error:nil].count == 0,
                          @"cancellation exposed a partial extraction");
    }
    for (NSString *name in [fm contentsOfDirectoryAtPath:root error:nil]) {
        require_condition(![name hasPrefix:[NSString stringWithFormat:@".%@.extract-", destination.lastPathComponent]],
                          @"cancellation left a private staging directory behind");
    }
}

// ---- .deb / tar fixtures ----------------------------------------------------

static NSData *tar_header(NSString *name, NSUInteger size, char type)
{
    uint8_t h[512] = {0};
    NSData *n = [name dataUsingEncoding:NSUTF8StringEncoding];
    memcpy(h, n.bytes, MIN(n.length, (NSUInteger)100));
    snprintf((char *)h + 100, 8, "%07o", 0644);
    snprintf((char *)h + 108, 8, "%07o", 0);
    snprintf((char *)h + 116, 8, "%07o", 0);
    snprintf((char *)h + 124, 12, "%011lo", (unsigned long)size);
    snprintf((char *)h + 136, 12, "%011o", 0);
    memset(h + 148, ' ', 8);
    h[156] = (uint8_t)type;
    memcpy(h + 257, "ustar", 5);
    memcpy(h + 263, "00", 2);
    unsigned sum = 0;
    for (int i = 0; i < 512; i++) sum += h[i];
    snprintf((char *)h + 148, 8, "%06o", sum);
    return [NSData dataWithBytes:h length:512];
}

static void tar_append(NSMutableData *tar, NSString *name, NSData *data, char type)
{
    [tar appendData:tar_header(name, data.length, type)];
    [tar appendData:data];
    NSUInteger pad = (512 - data.length % 512) % 512;
    if (pad) [tar increaseLengthBy:pad];
}

static NSData *tar_finish(NSMutableData *tar)
{
    [tar increaseLengthBy:1024];
    return tar;
}

static NSData *make_deb(NSData *dataTar)
{
    NSMutableData *deb = [NSMutableData dataWithBytes:"!<arch>\n" length:8];
    void (^member)(NSString *, NSData *) = ^(NSString *name, NSData *body) {
        char header[61];
        snprintf(header, sizeof(header), "%-16s%-12d%-6d%-6d%-8o%-10lu`\n",
                 name.UTF8String, 0, 0, 0, 0100644, (unsigned long)body.length);
        [deb appendBytes:header length:60];
        [deb appendData:body];
        if (body.length & 1) [deb appendBytes:"\n" length:1];
    };
    member(@"debian-binary", [@"2.0\n" dataUsingEncoding:NSUTF8StringEncoding]);
    member(@"data.tar", dataTar);
    return deb;
}

static void expect_deb_file(NSData *deb, NSString *root, NSString *caseName,
                            NSString *entryName, NSData *expected)
{
    NSString *archiveName = [caseName stringByAppendingString:@".deb"];
    NSString *destination = [root stringByAppendingPathComponent:
                              [caseName stringByAppendingString:@"-output"]];
    write_archive(deb, root, archiveName);
    NSError *error = nil;
    BOOL ok = SBLExtractArchiveToDirectory([NSURL fileURLWithPath:
                                            [root stringByAppendingPathComponent:archiveName]],
                                           destination, &error);
    require_condition(ok, [NSString stringWithFormat:@"%@ should extract: %@", caseName,
                            error.localizedDescription]);
    NSData *actual = [NSData dataWithContentsOfFile:
                      [destination stringByAppendingPathComponent:entryName]];
    require_condition([actual isEqualToData:expected],
                      [NSString stringWithFormat:@"%@: %@ missing or wrong", caseName, entryName]);
}

static void expect_deb_failure(NSData *deb, NSString *root, NSString *caseName)
{
    NSString *archiveName = [caseName stringByAppendingString:@".deb"];
    NSString *destination = [root stringByAppendingPathComponent:
                              [caseName stringByAppendingString:@"-output"]];
    write_archive(deb, root, archiveName);
    NSError *error = nil;
    BOOL ok = SBLExtractArchiveToDirectory([NSURL fileURLWithPath:
                                            [root stringByAppendingPathComponent:archiveName]],
                                           destination, &error);
    require_condition(!ok, [NSString stringWithFormat:@"%@ should be rejected", caseName]);
    require_condition(![[NSFileManager defaultManager] fileExistsAtPath:destination],
                      [NSString stringWithFormat:@"%@ left a destination behind", caseName]);
}

static void run_tar_long_name_cases(NSString *root)
{
    NSData *payload = [@"long path payload" dataUsingEncoding:NSUTF8StringEncoding];
    // 120+ bytes: does not fit the 100-byte ustar name field.
    NSString *longPath = [NSString stringWithFormat:@"Library/Themes/Example.theme/IconBundles/%@-large.png",
                          [@"" stringByPaddingToLength:90 withString:@"com.example.application." startingAtIndex:0]];
    require_condition([longPath dataUsingEncoding:NSUTF8StringEncoding].length > 100, @"fixture path must exceed 100 bytes");
    NSString *cutPath = [longPath substringToIndex:100];

    // A short name still works.
    NSMutableData *plain = [NSMutableData data];
    tar_append(plain, @"short.txt", payload, '0');
    expect_deb_file(make_deb(tar_finish(plain)), root, @"tar-short", @"short.txt", payload);

    // GNU: an 'L' record carries the full name of the next entry.
    NSMutableData *gnu = [NSMutableData data];
    NSMutableData *nameRecord = [[longPath dataUsingEncoding:NSUTF8StringEncoding] mutableCopy];
    [nameRecord increaseLengthBy:1];
    tar_append(gnu, @"././@LongLink", nameRecord, 'L');
    tar_append(gnu, cutPath, payload, '0');
    expect_deb_file(make_deb(tar_finish(gnu)), root, @"tar-gnu-long", longPath, payload);

    // pax: an 'x' record with "<len> path=<name>\n".
    NSMutableData *pax = [NSMutableData data];
    NSString *body = [NSString stringWithFormat:@" path=%@\n", longPath];
    NSUInteger total = [body dataUsingEncoding:NSUTF8StringEncoding].length;
    NSUInteger withDigits = total + [NSString stringWithFormat:@"%lu", (unsigned long)total].length;
    withDigits = total + [NSString stringWithFormat:@"%lu", (unsigned long)withDigits].length;
    NSString *record = [NSString stringWithFormat:@"%lu%@", (unsigned long)withDigits, body];
    require_condition([record dataUsingEncoding:NSUTF8StringEncoding].length == withDigits, @"pax record length must be self-consistent");
    tar_append(pax, @"PaxHeader/entry", [record dataUsingEncoding:NSUTF8StringEncoding], 'x');
    tar_append(pax, cutPath, payload, '0');
    expect_deb_file(make_deb(tar_finish(pax)), root, @"tar-pax-long", longPath, payload);

    // A long name is checked like a header name: it cannot leave the destination.
    NSMutableData *escape = [NSMutableData data];
    NSMutableData *evil = [[@"../../outside.txt" dataUsingEncoding:NSUTF8StringEncoding] mutableCopy];
    [evil increaseLengthBy:1];
    tar_append(escape, @"././@LongLink", evil, 'L');
    tar_append(escape, @"inside.txt", payload, '0');
    expect_deb_failure(make_deb(tar_finish(escape)), root, @"tar-long-escape");
    require_condition(![[NSFileManager defaultManager] fileExistsAtPath:
                        [root.stringByDeletingLastPathComponent stringByAppendingPathComponent:@"outside.txt"]],
                      @"a long name escaped the destination");
}

int main(void)
{
    @autoreleasepool {
        NSString *root = make_temp_root();
        NSFileManager *fm = [NSFileManager defaultManager];
        NSData *storedData = [@"stored archive payload" dataUsingEncoding:NSUTF8StringEncoding];
        NSData *deflatedData = [@"deflated archive payload with the same output size" dataUsingEncoding:NSUTF8StringEncoding];

        expect_success(make_zip(@[entry(@"stored.txt", storedData, 0, 0, NO, NO)]),
                       root, @"valid-stored", @"stored.txt", storedData);
        expect_success(make_zip(@[entry(@"deflated.txt", deflatedData, 8, 0, NO, NO)]),
                       root, @"valid-deflated", @"deflated.txt", deflatedData);

        expect_success(make_zip(@[entry(@"levels.txt", deflatedData, 8, 6, NO, NO)]),
                       root, @"deflate-level-options", @"levels.txt", deflatedData);
        expect_success(make_zip(@[entry(@"empty.txt", [NSData data], 8, 0, NO, NO)]),
                       root, @"empty-deflated", @"empty.txt", [NSData data]);
        expect_success(make_zip(@[
                           entry_with_compressed(@"empty-directory/", [NSData data], 8,
                                                 0, NO, NO, empty_fixed_deflate()),
                           entry(@"valid.txt", storedData, 0, 0, NO, NO),
                       ]), root, @"empty-deflated-directory", @"valid.txt", storedData);
        expect_failure(make_zip(@[
                           entry_with_compressed(@"huge-directory/", [NSData data], 8,
                                                 0, NO, NO, zero_output_deflate_stream(20000)),
                           entry(@"valid.txt", storedData, 0, 0, NO, NO),
                       ]), root, @"huge-zero-output-directory", NO);
        expect_failure(make_zip(@[entry(@"not-a-file/", storedData, 0, 0, NO, NO),
                                 entry(@"valid.txt", storedData, 0, 0, NO, NO)]),
                       root, @"directory-payload", NO);
        expect_failure(make_zip(@[
                           entry(@"alias/", [NSData data], 0, 0, NO, NO),
                           entry(@"alias", storedData, 0, 0, NO, NO),
                       ]), root, @"file-directory-alias", NO);

        if (filesystem_treats_paths_as_equivalent(root, @"same.txt", @"SAME.TXT")) {
            expect_failure(make_zip(@[
                               entry(@"same.txt", storedData, 0, 0, NO, NO),
                               entry(@"SAME.TXT", deflatedData, 0, 0, NO, NO),
                           ]), root, @"case-folded-alias", NO);
        }
        NSString *composed = @"café.txt";
        NSString *decomposed = @"cafe\u0301.txt";
        if (filesystem_treats_paths_as_equivalent(root, composed, decomposed)) {
            expect_failure(make_zip(@[
                               entry(composed, storedData, 0, 0, NO, NO),
                               entry(decomposed, deflatedData, 0, 0, NO, NO),
                           ]), root, @"canonical-normalization-alias", NO);
        }

        NSData *cancellationArchive = make_zip(@[
            entry(@"cancel.txt", storedData, 0, 0, NO, NO),
        ]);
        expect_cancellation(cancellationArchive, root, @"cancel-after-final-entry", 4, YES);
        expect_cancellation(cancellationArchive, root, @"cancel-before-commit", 5, NO);

        expect_failure(make_zip(@[entry(@"stored.txt", storedData, 0, 0, NO, YES)]),
                       root, @"corrupt-stored", NO);
        expect_failure(make_zip(@[entry(@"deflated.txt", deflatedData, 8, 0, NO, YES)]),
                       root, @"corrupt-deflated", NO);
        expect_failure(make_zip(@[entry(@"encrypted.txt", storedData, 0, 1, NO, NO)]),
                       root, @"encrypted", NO);
        expect_failure(make_zip(@[entry(@"unsupported.txt", storedData, 0, 2, NO, NO)]),
                       root, @"unsupported-flags", NO);

        NSData *descriptorData = [@"ordinary descriptor payload" dataUsingEncoding:NSUTF8StringEncoding];
        expect_success(make_zip(@[entry(@"descriptor-signed.txt", descriptorData, 8,
                                         1u << 3, YES, NO)]),
                       root, @"descriptor-signed", @"descriptor-signed.txt", descriptorData);
        expect_success(make_zip(@[entry(@"descriptor-unsigned.txt", descriptorData, 0,
                                         1u << 3, NO, NO)]),
                       root, @"descriptor-unsigned", @"descriptor-unsigned.txt", descriptorData);

        NSString *utf8Name = @"utf8-✓.txt";
        NSData *utf8Data = [@"UTF-8 archive payload" dataUsingEncoding:NSUTF8StringEncoding];
        expect_success(make_zip(@[entry(utf8Name, utf8Data, 8,
                                         (1u << 3) | (1u << 11), YES, NO)]),
                       root, @"utf8-descriptor", utf8Name, utf8Data);

        NSData *firstData = [@"first entry" dataUsingEncoding:NSUTF8StringEncoding];
        NSData *secondData = [@"second entry" dataUsingEncoding:NSUTF8StringEncoding];
        NSData *rollbackArchive = make_zip(@[
            entry(@"first.txt", firstData, 0, 0, NO, NO),
            entry(@"second.txt", secondData, 0, 0, NO, YES),
        ]);
        expect_failure(rollbackArchive, root, @"rollback", YES);
        NSArray *leftovers = [fm contentsOfDirectoryAtPath:root error:nil];
        for (NSString *name in leftovers) {
            require_condition(![name hasPrefix:@".rollback-output.extract-"],
                              @"rollback left a staging directory behind");
        }

        run_tar_long_name_cases(root);

        [fm removeItemAtPath:root error:nil];
        puts("archive integrity native fixtures: PASS");
    }
    return 0;
}
