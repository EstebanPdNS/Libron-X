# Source map

All maintained source files in v0.1, grouped by responsibility. See [architecture](architecture.md) for ownership and runtime boundaries.

## BibliotecaMac/App

- [BibliotecaApp.swift](../BibliotecaLibre/Sources/BibliotecaMac/App/BibliotecaApp.swift)

## BibliotecaMac/Features/Collections

- [CollectionsExplorer.swift](../BibliotecaLibre/Sources/BibliotecaMac/Features/Collections/CollectionsExplorer.swift)

## BibliotecaMac/Features/Library

- [FavoritesWorkspace.swift](../BibliotecaLibre/Sources/BibliotecaMac/Features/Library/FavoritesWorkspace.swift)
- [LibraryModel.swift](../BibliotecaLibre/Sources/BibliotecaMac/Features/Library/LibraryModel.swift)
- [LibraryStore.swift](../BibliotecaLibre/Sources/BibliotecaMac/Features/Library/LibraryStore.swift)
- [LibraryWorkspace.swift](../BibliotecaLibre/Sources/BibliotecaMac/Features/Library/LibraryWorkspace.swift)
- [PersonalLibraryStore.swift](../BibliotecaLibre/Sources/BibliotecaMac/Features/Library/PersonalLibraryStore.swift)
- [StudyDocumentsStore.swift](../BibliotecaLibre/Sources/BibliotecaMac/Features/Library/StudyDocumentsStore.swift)
- [StudyDocumentsWorkspace.swift](../BibliotecaLibre/Sources/BibliotecaMac/Features/Library/StudyDocumentsWorkspace.swift)

## BibliotecaMac/Features/Reader

- [BibleCopyModel.swift](../BibliotecaLibre/Sources/BibliotecaMac/Features/Reader/BibleCopyModel.swift)
- [BibleCopyWorkspace.swift](../BibliotecaLibre/Sources/BibliotecaMac/Features/Reader/BibleCopyWorkspace.swift)
- [ReaderOutputModel.swift](../BibliotecaLibre/Sources/BibliotecaMac/Features/Reader/ReaderOutputModel.swift)
- [ReaderOutputWorkspace.swift](../BibliotecaLibre/Sources/BibliotecaMac/Features/Reader/ReaderOutputWorkspace.swift)
- [ReaderTextView.swift](../BibliotecaLibre/Sources/BibliotecaMac/Features/Reader/ReaderTextView.swift)
- [ResourceOverview.swift](../BibliotecaLibre/Sources/BibliotecaMac/Features/Reader/ResourceOverview.swift)
- [ResourceReaderModel.swift](../BibliotecaLibre/Sources/BibliotecaMac/Features/Reader/ResourceReaderModel.swift)
- [ResourceWorkspace.swift](../BibliotecaLibre/Sources/BibliotecaMac/Features/Reader/ResourceWorkspace.swift)

## BibliotecaMac/Features/Search

- [LibrarySearchModel.swift](../BibliotecaLibre/Sources/BibliotecaMac/Features/Search/LibrarySearchModel.swift)
- [LibrarySearchWorkspace.swift](../BibliotecaLibre/Sources/BibliotecaMac/Features/Search/LibrarySearchWorkspace.swift)

## CLibronxCompression

- [blast.c](../BibliotecaLibre/Sources/CLibronxCompression/blast.c)
- [blast.h](../BibliotecaLibre/Sources/CLibronxCompression/blast.h)
- [wrapper.c](../BibliotecaLibre/Sources/CLibronxCompression/wrapper.c)

## CLibronxCompression/include

- [LibronxCompression.h](../BibliotecaLibre/Sources/CLibronxCompression/include/LibronxCompression.h)

## LibronixCore/Domain

- [BibleCopyOutputStyle.swift](../BibliotecaLibre/Sources/LibronixCore/Domain/BibleCopyOutputStyle.swift)
- [BibleCopyPassage.swift](../BibliotecaLibre/Sources/LibronixCore/Domain/BibleCopyPassage.swift)
- [BibleCopyPersonalState.swift](../BibliotecaLibre/Sources/LibronixCore/Domain/BibleCopyPersonalState.swift)
- [BibleCopyRenderIdentity.swift](../BibliotecaLibre/Sources/LibronixCore/Domain/BibleCopyRenderIdentity.swift)
- [CatalogQuery.swift](../BibliotecaLibre/Sources/LibronixCore/Domain/CatalogQuery.swift)
- [LibraryResource.swift](../BibliotecaLibre/Sources/LibronixCore/Domain/LibraryResource.swift)
- [PersonalLibraryState.swift](../BibliotecaLibre/Sources/LibronixCore/Domain/PersonalLibraryState.swift)
- [ReaderOutputDocument.swift](../BibliotecaLibre/Sources/LibronixCore/Domain/ReaderOutputDocument.swift)
- [ReaderPrintSettings.swift](../BibliotecaLibre/Sources/LibronixCore/Domain/ReaderPrintSettings.swift)
- [ReadingHistory.swift](../BibliotecaLibre/Sources/LibronixCore/Domain/ReadingHistory.swift)
- [StudyDocument.swift](../BibliotecaLibre/Sources/LibronixCore/Domain/StudyDocument.swift)
- [WorkspaceDocument.swift](../BibliotecaLibre/Sources/LibronixCore/Domain/WorkspaceDocument.swift)

## LibronixCore/Formats

- [BibleCopyFormatter.swift](../BibliotecaLibre/Sources/LibronixCore/Formats/BibleCopyFormatter.swift)
- [BibleCopyScriptProjection.swift](../BibliotecaLibre/Sources/LibronixCore/Formats/BibleCopyScriptProjection.swift)
- [BibleCopyTransliterator.swift](../BibliotecaLibre/Sources/LibronixCore/Formats/BibleCopyTransliterator.swift)
- [LTESContainerReader.swift](../BibliotecaLibre/Sources/LibronixCore/Formats/LTESContainerReader.swift)
- [LegacyBagReader.swift](../BibliotecaLibre/Sources/LibronixCore/Formats/LegacyBagReader.swift)
- [LegacyBodyIndex.swift](../BibliotecaLibre/Sources/LibronixCore/Formats/LegacyBodyIndex.swift)
- [LegacyCompactPostingsReader.swift](../BibliotecaLibre/Sources/LibronixCore/Formats/LegacyCompactPostingsReader.swift)
- [LegacyContentReader.swift](../BibliotecaLibre/Sources/LibronixCore/Formats/LegacyContentReader.swift)
- [LegacyDictionaryReader.swift](../BibliotecaLibre/Sources/LibronixCore/Formats/LegacyDictionaryReader.swift)
- [LegacyDocumentDecoder.swift](../BibliotecaLibre/Sources/LibronixCore/Formats/LegacyDocumentDecoder.swift)
- [LegacyIndicesReader.swift](../BibliotecaLibre/Sources/LibronixCore/Formats/LegacyIndicesReader.swift)
- [LegacyInlineLinks.swift](../BibliotecaLibre/Sources/LibronixCore/Formats/LegacyInlineLinks.swift)
- [LegacyInterlinear.swift](../BibliotecaLibre/Sources/LibronixCore/Formats/LegacyInterlinear.swift)
- [LegacyJumpDestination.swift](../BibliotecaLibre/Sources/LibronixCore/Formats/LegacyJumpDestination.swift)
- [LegacyLanguageProfileReader.swift](../BibliotecaLibre/Sources/LibronixCore/Formats/LegacyLanguageProfileReader.swift)
- [LegacyLocator.swift](../BibliotecaLibre/Sources/LibronixCore/Formats/LegacyLocator.swift)
- [LegacyLocatorResolution.swift](../BibliotecaLibre/Sources/LibronixCore/Formats/LegacyLocatorResolution.swift)
- [LegacyNavigation.swift](../BibliotecaLibre/Sources/LibronixCore/Formats/LegacyNavigation.swift)
- [LegacyPostingsReader.swift](../BibliotecaLibre/Sources/LibronixCore/Formats/LegacyPostingsReader.swift)
- [LegacyReferenceMapReader.swift](../BibliotecaLibre/Sources/LibronixCore/Formats/LegacyReferenceMapReader.swift)
- [LegacyResourceReader.swift](../BibliotecaLibre/Sources/LibronixCore/Formats/LegacyResourceReader.swift)
- [LegacyTypography.swift](../BibliotecaLibre/Sources/LibronixCore/Formats/LegacyTypography.swift)
- [LibronixBookArchive.swift](../BibliotecaLibre/Sources/LibronixCore/Formats/LibronixBookArchive.swift)
- [LibronixOEB.swift](../BibliotecaLibre/Sources/LibronixCore/Formats/LibronixOEB.swift)
- [LibronixTopicIndexReader.swift](../BibliotecaLibre/Sources/LibronixCore/Formats/LibronixTopicIndexReader.swift)
- [ReaderOutputEncoder.swift](../BibliotecaLibre/Sources/LibronixCore/Formats/ReaderOutputEncoder.swift)
- [SCSUDecoder.swift](../BibliotecaLibre/Sources/LibronixCore/Formats/SCSUDecoder.swift)

## LibronixCore/Import

- [BibleCopyService.swift](../BibliotecaLibre/Sources/LibronixCore/Import/BibleCopyService.swift)
- [BibleCopyStyleFileService.swift](../BibliotecaLibre/Sources/LibronixCore/Import/BibleCopyStyleFileService.swift)
- [LegacyContentService.swift](../BibliotecaLibre/Sources/LibronixCore/Import/LegacyContentService.swift)
- [LegacyGraphicsService.swift](../BibliotecaLibre/Sources/LibronixCore/Import/LegacyGraphicsService.swift)
- [LibraryImporter.swift](../BibliotecaLibre/Sources/LibronixCore/Import/LibraryImporter.swift)
- [LibronixBookService.swift](../BibliotecaLibre/Sources/LibronixCore/Import/LibronixBookService.swift)
- [LibronixTopicCatalogService.swift](../BibliotecaLibre/Sources/LibronixCore/Import/LibronixTopicCatalogService.swift)
- [MetadataService.swift](../BibliotecaLibre/Sources/LibronixCore/Import/MetadataService.swift)
- [ReaderOutputService.swift](../BibliotecaLibre/Sources/LibronixCore/Import/ReaderOutputService.swift)
- [ResourceDirectoryEnumerator.swift](../BibliotecaLibre/Sources/LibronixCore/Import/ResourceDirectoryEnumerator.swift)

## LibronixCore/Metadata

- [LibronixTopicIndexDeclaration.swift](../BibliotecaLibre/Sources/LibronixCore/Metadata/LibronixTopicIndexDeclaration.swift)
- [MetadataImporter.swift](../BibliotecaLibre/Sources/LibronixCore/Metadata/MetadataImporter.swift)
- [MetadataModels.swift](../BibliotecaLibre/Sources/LibronixCore/Metadata/MetadataModels.swift)
- [XMLNode.swift](../BibliotecaLibre/Sources/LibronixCore/Metadata/XMLNode.swift)

## LibronixCore/Search

- [BibleVerseText.swift](../BibliotecaLibre/Sources/LibronixCore/Search/BibleVerseText.swift)
- [LegacyQueryParser.swift](../BibliotecaLibre/Sources/LibronixCore/Search/LegacyQueryParser.swift)
- [LibrarySearchModels.swift](../BibliotecaLibre/Sources/LibronixCore/Search/LibrarySearchModels.swift)
- [LibrarySearchReader.swift](../BibliotecaLibre/Sources/LibronixCore/Search/LibrarySearchReader.swift)
- [LibrarySearchService.swift](../BibliotecaLibre/Sources/LibronixCore/Search/LibrarySearchService.swift)
- [SearchQuery.swift](../BibliotecaLibre/Sources/LibronixCore/Search/SearchQuery.swift)
- [TextSearchEngine.swift](../BibliotecaLibre/Sources/LibronixCore/Search/TextSearchEngine.swift)

## LibronixInspect

- [DocumentInspection.swift](../BibliotecaLibre/Sources/LibronixInspect/DocumentInspection.swift)
- [InspectCommand.swift](../BibliotecaLibre/Sources/LibronixInspect/InspectCommand.swift)
- [LanguageInspection.swift](../BibliotecaLibre/Sources/LibronixInspect/LanguageInspection.swift)
- [LocatorInspection.swift](../BibliotecaLibre/Sources/LibronixInspect/LocatorInspection.swift)
- [OutputInspection.swift](../BibliotecaLibre/Sources/LibronixInspect/OutputInspection.swift)
- [PostingsInspection.swift](../BibliotecaLibre/Sources/LibronixInspect/PostingsInspection.swift)
- [ResourceFormatInspection.swift](../BibliotecaLibre/Sources/LibronixInspect/ResourceFormatInspection.swift)
- [SearchInspection.swift](../BibliotecaLibre/Sources/LibronixInspect/SearchInspection.swift)
- [TopicInspection.swift](../BibliotecaLibre/Sources/LibronixInspect/TopicInspection.swift)

## LibronixOutputMac

- [NativeBibleCopyOutput.swift](../BibliotecaLibre/Sources/LibronixOutputMac/NativeBibleCopyOutput.swift)
- [NativeReaderOutput.swift](../BibliotecaLibre/Sources/LibronixOutputMac/NativeReaderOutput.swift)

## MacRebuild/App

- [AppIconPreferences.swift](../BibliotecaLibre/Sources/MacRebuild/App/AppIconPreferences.swift)
- [AppLanguage.swift](../BibliotecaLibre/Sources/MacRebuild/App/AppLanguage.swift)
- [AppPreferences.swift](../BibliotecaLibre/Sources/MacRebuild/App/AppPreferences.swift)
- [MacApplicationIdentity.swift](../BibliotecaLibre/Sources/MacRebuild/App/MacApplicationIdentity.swift)
- [RebuildApp.swift](../BibliotecaLibre/Sources/MacRebuild/App/RebuildApp.swift)
- [StudyRootView.swift](../BibliotecaLibre/Sources/MacRebuild/App/StudyRootView.swift)

## MacRebuild/Features/BibleCopy

- [BibleCopyToolView.swift](../BibliotecaLibre/Sources/MacRebuild/Features/BibleCopy/BibleCopyToolView.swift)

## MacRebuild/Features/Documents

- [WorkspaceDocumentsView.swift](../BibliotecaLibre/Sources/MacRebuild/Features/Documents/WorkspaceDocumentsView.swift)

## MacRebuild/Features/Library

- [LibraryChooser.swift](../BibliotecaLibre/Sources/MacRebuild/Features/Library/LibraryChooser.swift)

## MacRebuild/Features/Reader/OEB

- [ReaderOEBFind.swift](../BibliotecaLibre/Sources/MacRebuild/Features/Reader/OEB/ReaderOEBFind.swift)
- [ReaderOEBOutput.swift](../BibliotecaLibre/Sources/MacRebuild/Features/Reader/OEB/ReaderOEBOutput.swift)
- [ReaderOEBTextSource.swift](../BibliotecaLibre/Sources/MacRebuild/Features/Reader/OEB/ReaderOEBTextSource.swift)
- [ReaderOEBView.swift](../BibliotecaLibre/Sources/MacRebuild/Features/Reader/OEB/ReaderOEBView.swift)

## MacRebuild/Features/Reader/Output

- [ReaderOutputActions.swift](../BibliotecaLibre/Sources/MacRebuild/Features/Reader/Output/ReaderOutputActions.swift)

## MacRebuild/Features/Reader

- [ReaderArticleFlow.swift](../BibliotecaLibre/Sources/MacRebuild/Features/Reader/ReaderArticleFlow.swift)
- [ReaderBibleIndex.swift](../BibliotecaLibre/Sources/MacRebuild/Features/Reader/ReaderBibleIndex.swift)
- [ReaderError.swift](../BibliotecaLibre/Sources/MacRebuild/Features/Reader/ReaderError.swift)
- [ReaderFind.swift](../BibliotecaLibre/Sources/MacRebuild/Features/Reader/ReaderFind.swift)
- [ReaderFindBar.swift](../BibliotecaLibre/Sources/MacRebuild/Features/Reader/ReaderFindBar.swift)
- [ReaderLinkPreview.swift](../BibliotecaLibre/Sources/MacRebuild/Features/Reader/ReaderLinkPreview.swift)
- [ReaderLinkRouting.swift](../BibliotecaLibre/Sources/MacRebuild/Features/Reader/ReaderLinkRouting.swift)
- [ReaderPassageParts.swift](../BibliotecaLibre/Sources/MacRebuild/Features/Reader/ReaderPassageParts.swift)
- [ReaderSession.swift](../BibliotecaLibre/Sources/MacRebuild/Features/Reader/ReaderSession.swift)

## MacRebuild/Features/Reader/Rendering

- [MapPreview.swift](../BibliotecaLibre/Sources/MacRebuild/Features/Reader/Rendering/MapPreview.swift)
- [ReaderArticleFlowView.swift](../BibliotecaLibre/Sources/MacRebuild/Features/Reader/Rendering/ReaderArticleFlowView.swift)
- [ReaderImageRenderer.swift](../BibliotecaLibre/Sources/MacRebuild/Features/Reader/Rendering/ReaderImageRenderer.swift)
- [ReaderInterlinearLayout.swift](../BibliotecaLibre/Sources/MacRebuild/Features/Reader/Rendering/ReaderInterlinearLayout.swift)
- [ReaderLayoutManager.swift](../BibliotecaLibre/Sources/MacRebuild/Features/Reader/Rendering/ReaderLayoutManager.swift)
- [ReaderResourceFonts.swift](../BibliotecaLibre/Sources/MacRebuild/Features/Reader/Rendering/ReaderResourceFonts.swift)
- [ReaderTableLayout.swift](../BibliotecaLibre/Sources/MacRebuild/Features/Reader/Rendering/ReaderTableLayout.swift)
- [ReaderTextView.swift](../BibliotecaLibre/Sources/MacRebuild/Features/Reader/Rendering/ReaderTextView.swift)
- [ReaderTypography.swift](../BibliotecaLibre/Sources/MacRebuild/Features/Reader/Rendering/ReaderTypography.swift)

## MacRebuild/Features/Search

- [WorkspaceSearchController.swift](../BibliotecaLibre/Sources/MacRebuild/Features/Search/WorkspaceSearchController.swift)

## MacRebuild/Features/Settings

- [AppSettingsView.swift](../BibliotecaLibre/Sources/MacRebuild/Features/Settings/AppSettingsView.swift)
- [LibrarySettingsView.swift](../BibliotecaLibre/Sources/MacRebuild/Features/Settings/LibrarySettingsView.swift)
- [ParallelBibleSettingsView.swift](../BibliotecaLibre/Sources/MacRebuild/Features/Settings/ParallelBibleSettingsView.swift)

## MacRebuild/Features/Topics

- [TopicBrowserView.swift](../BibliotecaLibre/Sources/MacRebuild/Features/Topics/TopicBrowserView.swift)
- [TopicSearchController.swift](../BibliotecaLibre/Sources/MacRebuild/Features/Topics/TopicSearchController.swift)

## MacRebuild/Persistence

- [LibraryResourceVisibility.swift](../BibliotecaLibre/Sources/MacRebuild/Persistence/LibraryResourceVisibility.swift)
- [ParallelBibleSets.swift](../BibliotecaLibre/Sources/MacRebuild/Persistence/ParallelBibleSets.swift)
- [RecentWorkspaces.swift](../BibliotecaLibre/Sources/MacRebuild/Persistence/RecentWorkspaces.swift)
- [WorkspaceFiles.swift](../BibliotecaLibre/Sources/MacRebuild/Persistence/WorkspaceFiles.swift)
- [WorkspacePersonalState.swift](../BibliotecaLibre/Sources/MacRebuild/Persistence/WorkspacePersonalState.swift)
- [WorkspaceStartup.swift](../BibliotecaLibre/Sources/MacRebuild/Persistence/WorkspaceStartup.swift)

## MacRebuild/Resources

- [Interface.json](../BibliotecaLibre/Sources/MacRebuild/Resources/Interface.json)

## MacRebuild/Shared/Controls

- [MacInputPresentation.swift](../BibliotecaLibre/Sources/MacRebuild/Shared/Controls/MacInputPresentation.swift)
- [MacToolbarPresentation.swift](../BibliotecaLibre/Sources/MacRebuild/Shared/Controls/MacToolbarPresentation.swift)

## MacRebuild/Workspace

- [BibleVersionKeyboardRouting.swift](../BibliotecaLibre/Sources/MacRebuild/Workspace/BibleVersionKeyboardRouting.swift)
- [ParallelBibleMenu.swift](../BibliotecaLibre/Sources/MacRebuild/Workspace/ParallelBibleMenu.swift)
- [StudyDesktop.swift](../BibliotecaLibre/Sources/MacRebuild/Workspace/StudyDesktop.swift)
- [StudyWorkspace.swift](../BibliotecaLibre/Sources/MacRebuild/Workspace/StudyWorkspace.swift)
- [WorkspaceActions.swift](../BibliotecaLibre/Sources/MacRebuild/Workspace/WorkspaceActions.swift)
- [WorkspaceBibleVersions.swift](../BibliotecaLibre/Sources/MacRebuild/Workspace/WorkspaceBibleVersions.swift)
- [WorkspaceToolbars.swift](../BibliotecaLibre/Sources/MacRebuild/Workspace/WorkspaceToolbars.swift)
- [WorkspaceToolsView.swift](../BibliotecaLibre/Sources/MacRebuild/Workspace/WorkspaceToolsView.swift)
- [WorkspaceWindowSelection.swift](../BibliotecaLibre/Sources/MacRebuild/Workspace/WorkspaceWindowSelection.swift)
- [WorkspaceWindowsView.swift](../BibliotecaLibre/Sources/MacRebuild/Workspace/WorkspaceWindowsView.swift)
