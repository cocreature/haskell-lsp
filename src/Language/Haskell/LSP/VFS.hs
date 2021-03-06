{-# LANGUAGE CPP #-}
{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE ScopedTypeVariables #-}

{-

Manage the J.TextDocumentDidChange messages to keep a local copy of the files
in the client workspace, so that tools at the server can operate on them.
-}
module Language.Haskell.LSP.VFS
  (
    VFS
  , VirtualFile(..)
  , openVFS
  , changeFromClientVFS
  , changeFromServerVFS
  , persistFileVFS
  , closeVFS

  -- * manipulating the file contents
  , rangeLinesFromVfs
  , PosPrefixInfo(..)
  , getCompletionPrefix

  -- * for tests
  , applyChanges
  , applyChange
  , changeChars
  ) where

import           Control.Lens hiding ( parts )
import           Control.Monad
import           Data.Char (isUpper, isAlphaNum)
import           Data.Text ( Text )
import qualified Data.Text as T
import           Data.List
import           Data.Ord
#if __GLASGOW_HASKELL__ < 804
import           Data.Monoid
#endif
import           System.IO.Temp
import qualified Data.HashMap.Strict as HashMap
import qualified Data.Map as Map
import           Data.Maybe
import           Data.Rope.UTF16 ( Rope )
import qualified Data.Rope.UTF16 as Rope
import qualified Language.Haskell.LSP.Types           as J
import qualified Language.Haskell.LSP.Types.Lens      as J
import           Language.Haskell.LSP.Utility

-- ---------------------------------------------------------------------
{-# ANN module ("hlint: ignore Eta reduce" :: String) #-}
{-# ANN module ("hlint: ignore Redundant do" :: String) #-}
-- ---------------------------------------------------------------------

data VirtualFile =
  VirtualFile {
      _version :: Int
    , _text    :: Rope
    , _tmp_file :: Maybe FilePath
    } deriving (Show)

type VFS = Map.Map J.Uri VirtualFile

-- ---------------------------------------------------------------------

openVFS :: VFS -> J.DidOpenTextDocumentNotification -> IO VFS
openVFS vfs (J.NotificationMessage _ _ params) = do
  let J.DidOpenTextDocumentParams
         (J.TextDocumentItem uri _ version text) = params
  return $ Map.insert uri (VirtualFile version (Rope.fromText text) Nothing) vfs

-- ---------------------------------------------------------------------

changeFromClientVFS :: VFS -> J.DidChangeTextDocumentNotification -> IO VFS
changeFromClientVFS vfs (J.NotificationMessage _ _ params) = do
  let
    J.DidChangeTextDocumentParams vid (J.List changes) = params
    J.VersionedTextDocumentIdentifier uri version = vid
  case Map.lookup uri vfs of
    Just (VirtualFile _ str _) -> do
      let str' = applyChanges str changes
      -- the client shouldn't be sending over a null version, only the server.
      return $ Map.insert uri (VirtualFile (fromMaybe 0 version) str' Nothing) vfs
    Nothing -> do
      logs $ "haskell-lsp:changeVfs:can't find uri:" ++ show uri
      return vfs

-- ---------------------------------------------------------------------

changeFromServerVFS :: VFS -> J.ApplyWorkspaceEditRequest -> IO VFS
changeFromServerVFS initVfs (J.RequestMessage _ _ _ params) = do
  let J.ApplyWorkspaceEditParams edit = params
      J.WorkspaceEdit mChanges mDocChanges = edit
  case mDocChanges of
    Just (J.List textDocEdits) -> applyEdits textDocEdits
    Nothing -> case mChanges of
      Just cs -> applyEdits $ HashMap.foldlWithKey' changeToTextDocumentEdit [] cs
      Nothing -> do
        logs "haskell-lsp:changeVfs:no changes"
        return initVfs

  where

    changeToTextDocumentEdit acc uri edits =
      acc ++ [J.TextDocumentEdit (J.VersionedTextDocumentIdentifier uri (Just 0)) edits]

    applyEdits = foldM f initVfs . sortOn (^. J.textDocument . J.version)

    f vfs (J.TextDocumentEdit vid (J.List edits)) = do
      -- all edits are supposed to be applied at once
      -- so apply from bottom up so they don't affect others
      let sortedEdits = sortOn (Down . (^. J.range)) edits
          changeEvents = map editToChangeEvent sortedEdits
          ps = J.DidChangeTextDocumentParams vid (J.List changeEvents)
          notif = J.NotificationMessage "" J.TextDocumentDidChange ps
      changeFromClientVFS vfs notif

    editToChangeEvent (J.TextEdit range text) = J.TextDocumentContentChangeEvent (Just range) Nothing text

-- ---------------------------------------------------------------------

persistFileVFS :: VFS -> J.Uri -> IO (FilePath, VFS)
persistFileVFS vfs uri =
  case Map.lookup uri vfs of
    Nothing -> error ("File not found in VFS: " ++ show uri ++ show vfs)
    Just (VirtualFile v txt tfile) ->
      case tfile of
        Just tfn -> return (tfn, vfs)
        Nothing  -> do
          fn <- writeSystemTempFile "VFS.hs" (Rope.toString txt)
          return (fn, Map.insert uri (VirtualFile v txt (Just fn)) vfs)

-- ---------------------------------------------------------------------

closeVFS :: VFS -> J.DidCloseTextDocumentNotification -> IO VFS
closeVFS vfs (J.NotificationMessage _ _ params) = do
  let J.DidCloseTextDocumentParams (J.TextDocumentIdentifier uri) = params
  return $ Map.delete uri vfs

-- ---------------------------------------------------------------------
{-

data TextDocumentContentChangeEvent =
  TextDocumentContentChangeEvent
    { _range       :: Maybe Range
    , _rangeLength :: Maybe Int
    , _text        :: String
    } deriving (Read,Show,Eq)
-}

-- | Apply the list of changes.
-- Changes should be applied in the order that they are
-- received from the client.
applyChanges :: Rope -> [J.TextDocumentContentChangeEvent] -> Rope
applyChanges = foldl' applyChange

-- ---------------------------------------------------------------------

applyChange :: Rope -> J.TextDocumentContentChangeEvent -> Rope
applyChange _ (J.TextDocumentContentChangeEvent Nothing Nothing str)
  = Rope.fromText str
applyChange str (J.TextDocumentContentChangeEvent (Just (J.Range (J.Position sl sc) _to)) (Just len) txt)
  = changeChars str start len txt
  where
    start = Rope.rowColumnCodeUnits (Rope.RowColumn sl sc) str
applyChange str (J.TextDocumentContentChangeEvent (Just (J.Range (J.Position sl sc) (J.Position el ec))) Nothing txt)
  = changeChars str start len txt
  where
    start = Rope.rowColumnCodeUnits (Rope.RowColumn sl sc) str
    end = Rope.rowColumnCodeUnits (Rope.RowColumn el ec) str
    len = end - start
applyChange str (J.TextDocumentContentChangeEvent Nothing (Just _) _txt)
  = str

-- ---------------------------------------------------------------------

changeChars :: Rope -> Int -> Int -> Text -> Rope
changeChars str start len new = mconcat [before, Rope.fromText new, after']
  where
    (before, after) = Rope.splitAt start str
    after' = Rope.drop len after

-- ---------------------------------------------------------------------

-- TODO:AZ:move this to somewhere sane
-- | Describes the line at the current cursor position
data PosPrefixInfo = PosPrefixInfo
  { fullLine :: T.Text
    -- ^ The full contents of the line the cursor is at

  , prefixModule :: T.Text
    -- ^ If any, the module name that was typed right before the cursor position.
    --  For example, if the user has typed "Data.Maybe.from", then this property
    --  will be "Data.Maybe"

  , prefixText :: T.Text
    -- ^ The word right before the cursor position, after removing the module part.
    -- For example if the user has typed "Data.Maybe.from",
    -- then this property will be "from"
  , cursorPos :: J.Position
    -- ^ The cursor position
  } deriving (Show,Eq)

getCompletionPrefix :: (Monad m) => J.Position -> VirtualFile -> m (Maybe PosPrefixInfo)
getCompletionPrefix pos@(J.Position l c) (VirtualFile _ yitext _) =
      return $ Just $ fromMaybe (PosPrefixInfo "" "" "" pos) $ do -- Maybe monad
        let headMaybe [] = Nothing
            headMaybe (x:_) = Just x
            lastMaybe [] = Nothing
            lastMaybe xs = Just $ last xs

        curLine <- headMaybe $ T.lines $ Rope.toText
                             $ fst $ Rope.splitAtLine 1 $ snd $ Rope.splitAtLine l yitext
        let beforePos = T.take c curLine
        curWord <- case T.last beforePos of
                     ' ' -> return "" -- don't count abc as the curword in 'abc '
                     _ -> lastMaybe (T.words beforePos)

        let parts = T.split (=='.')
                      $ T.takeWhileEnd (\x -> isAlphaNum x || x `elem` ("._'"::String)) curWord
        case reverse parts of
          [] -> Nothing
          (x:xs) -> do
            let modParts = dropWhile (not . isUpper . T.head)
                                $ reverse $ filter (not .T.null) xs
                modName = T.intercalate "." modParts
            return $ PosPrefixInfo curLine modName x pos

-- ---------------------------------------------------------------------

rangeLinesFromVfs :: VirtualFile -> J.Range -> T.Text
rangeLinesFromVfs (VirtualFile _ yitext _) (J.Range (J.Position lf _cf) (J.Position lt _ct)) = r
  where
    (_ ,s1) = Rope.splitAtLine lf yitext
    (s2, _) = Rope.splitAtLine (lt - lf) s1
    r = Rope.toText s2

-- ---------------------------------------------------------------------
