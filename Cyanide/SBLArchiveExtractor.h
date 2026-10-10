//
//  SBLArchiveExtractor.h
//  Cyanide
//  Adapted from https://github.com/d1y/cyanide-ios (AGPL-3.0).
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

// The destination is owned by the extractor: failed or cancelled extraction
// removes it so callers cannot accidentally import a partial tree.
BOOL SBLExtractArchiveToDirectory(NSURL *url, NSString *destination, NSError **error);

// `progress` may be cancelled by the caller. Work is still synchronous from
// the caller's perspective, so callers that handle user-selected documents
// should invoke this API from a background queue while retaining any
// security-scoped access until it returns.
BOOL SBLExtractArchiveToDirectoryWithProgress(NSURL *url,
                                              NSString *destination,
                                              NSProgress * _Nullable progress,
                                              NSError **error);

NS_ASSUME_NONNULL_END
