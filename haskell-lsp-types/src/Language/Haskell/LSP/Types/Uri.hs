{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE RecordWildCards #-}
module Language.Haskell.LSP.Types.Uri where

import           Control.DeepSeq
import qualified Data.Aeson                                 as A
import           Data.Hashable
import           Data.Text                                  (Text)
import qualified Data.Text                                  as T
import           GHC.Generics
import           Network.URI hiding (authority)
import qualified System.FilePath.Posix                      as FPP
import qualified System.FilePath.Windows                    as FPW
import qualified System.Info
import GHC.Stack

newtype Uri = Uri { getUri :: Text }
  deriving (Eq,Ord,Read,Show,Generic,A.FromJSON,A.ToJSON,Hashable,A.ToJSONKey,A.FromJSONKey)

instance NFData Uri

-- | When URIs are supposed to be used as keys, it is important to normalize
-- the percent encoding in the URI since URIs that only differ
-- when it comes to the percent-encoding should be treated as equivalent.
newtype NormalizedUri = NormalizedUri Text
  deriving (Eq,Ord,Read,Show,Generic,Hashable)

toNormalizedUri :: HasCallStack => Uri -> NormalizedUri
toNormalizedUri uri =
    NormalizedUri $ T.pack $ escapeURIString isUnescapedInURI $ unEscapeString $ T.unpack t
  where (Uri t) = maybe uri filePathToUri (uriToFilePath uri)
        -- To ensure all `Uri`s have the file path like the created ones by `filePathToUri`

fromNormalizedUri :: NormalizedUri -> Uri
fromNormalizedUri (NormalizedUri t) = Uri t

fileScheme :: String
fileScheme = "file:"

windowsOS :: String
windowsOS = "mingw32"

type SystemOS = String

uriToFilePath :: HasCallStack => Uri -> Maybe FilePath
uriToFilePath = platformAwareUriToFilePath System.Info.os

platformAwareUriToFilePath :: HasCallStack => String -> Uri -> Maybe FilePath
platformAwareUriToFilePath systemOS (Uri uri) = do
  URI{..} <- parseURI $ T.unpack uri
  if uriScheme == fileScheme
    then return $
      platformAdjustFromUriPath systemOS (uriRegName <$> uriAuthority) $ unEscapeString uriPath
    else Nothing

-- | We pull in the authority because in relative file paths the Uri likes to put everything before the slash
--   into the authority field
platformAdjustFromUriPath :: HasCallStack => SystemOS
                          -> Maybe String -- ^ authority
                          -> String -- ^ path
                          -> FilePath
platformAdjustFromUriPath systemOS authority srcPath =
  (maybe id (++) authority) $
  if systemOS /= windowsOS || null srcPath then srcPath
    else let
      firstSegment:rest = case (FPP.splitDirectories . tail) srcPath of
        a:b -> a:b
        _ -> error $ "Unsupported: " <> srcPath
      drive = if FPW.isDrive firstSegment then FPW.addTrailingPathSeparator firstSegment else firstSegment
      in FPW.joinDrive drive $ FPW.joinPath rest

filePathToUri :: FilePath -> Uri
filePathToUri = platformAwareFilePathToUri System.Info.os

platformAwareFilePathToUri :: SystemOS -> FilePath -> Uri
platformAwareFilePathToUri systemOS fp = Uri . T.pack . show $ URI
  { uriScheme = fileScheme
  , uriAuthority = Just $ URIAuth "" "" ""
  , uriPath = platformAdjustToUriPath systemOS fp
  , uriQuery = ""
  , uriFragment = ""
  }

platformAdjustToUriPath :: SystemOS -> FilePath -> String
platformAdjustToUriPath systemOS srcPath
  | systemOS == windowsOS = '/' : escapedPath
  | otherwise = escapedPath
  where
    (splitDirectories, splitDrive, normalise)
      | systemOS == windowsOS =
          (FPW.splitDirectories, FPW.splitDrive, FPW.normalise)
      | otherwise =
          (FPP.splitDirectories, FPP.splitDrive, FPP.normalise)
    escapedPath =
        case splitDrive (normalise srcPath) of
            (drv, rest) ->
                convertDrive drv `FPP.joinDrive`
                FPP.joinPath (map (escapeURIString unescaped) $ splitDirectories rest)
    -- splitDirectories does not remove the path separator after the drive so
    -- we do a final replacement of \ to /
    convertDrive drv
      | systemOS == windowsOS && FPW.hasTrailingPathSeparator drv =
          FPP.addTrailingPathSeparator (init drv)
      | otherwise = drv
    unescaped c
      | systemOS == windowsOS = isUnreserved c || c `elem` [':', '\\', '/']
      | otherwise = isUnreserved c || c == '/'
