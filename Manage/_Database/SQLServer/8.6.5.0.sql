truncate table dbversion;
go
insert into dbversion(dbversion) values ('8.6.5.0');
go
SET ARITHABORT ON

UPDATE	Template
SET		FeatureFlags = FeatureFlags | 256
FROM	Template
		CROSS APPLY Project_Definition.nodes('(/Intelledox_TemplateFile/Workflow/State)') as  StateXML(S)
		CROSS APPLY S.nodes('(Transition)') as TransitionXML(T)
WHERE	S.value('@ID', 'uniqueidentifier') = '11111111-1111-1111-1111-111111111111'
		AND (T.value('@SendToType', 'int') = 0 or T.value('@SendToType', 'int') IS NULL)
GO
SET ARITHABORT ON

UPDATE	Template_Version
SET		FeatureFlags = FeatureFlags | 256
FROM	Template_Version
		CROSS APPLY Project_Definition.nodes('(/Intelledox_TemplateFile/Workflow/State)') as  StateXML(S)
		CROSS APPLY S.nodes('(Transition)') as TransitionXML(T)
WHERE	S.value('@ID', 'uniqueidentifier') = '11111111-1111-1111-1111-111111111111'
		AND (T.value('@SendToType', 'int') = 0 or T.value('@SendToType', 'int') IS NULL)
GO
--Those that have workflow and workflow - specified, remove workflow
UPDATE	Template
SET		FeatureFlags = FeatureFlags ^ 1
WHERE	FeatureFlags & 1 = 1 
		AND FeatureFlags & 256 = 256;
GO
UPDATE	Template_Version
SET		FeatureFlags = FeatureFlags ^ 1
WHERE	FeatureFlags & 1 = 1 
		AND FeatureFlags & 256 = 256;
GO
-- Update existing project groups
UPDATE	Template_Group
SET		Template_Group.FeatureFlags = t.NewFeatureFlags
FROM	(SELECT Content.Template_Group_Guid, 
				CASE WHEN Layout.FeatureFlags IS NULL THEN Content.FeatureFlags ELSE Content.FeatureFlags | Layout.FeatureFlags END NewFeatureFlags
			FROM (
				SELECT	Template_Group.Template_Group_Guid, 
						Template.Template_Guid,
						Template.FeatureFlags
				FROM	Template_Group
						INNER JOIN Template ON Template_Group.Template_Guid = Template.Template_Guid 
								AND (Template_Group.Template_Version IS NULL
									OR Template_Group.Template_Version = Template.Template_Version)
				UNION ALL
				SELECT	Template_Group.Template_Group_Guid, 
						Template_Version.Template_Guid, 
						Template_Version.FeatureFlags
				FROM	Template_Group
						INNER JOIN Template ON Template_Group.Template_Guid = Template.Template_Guid
						INNER JOIN Template_Version ON (Template_Group.Template_Guid = Template_Version.Template_Guid 
								AND Template_Group.Template_Version = Template_Version.Template_Version)
				) Content
			LEFT JOIN (
				SELECT	Template_Group.Template_Group_Guid, 
						Template.Template_Guid,
						Template.FeatureFlags
				FROM	Template_Group
						INNER JOIN Template ON Template_Group.Layout_Guid = Template.Template_Guid
								AND (Template_Group.Layout_Version IS NULL
									OR Template_Group.Layout_Version = Template.Template_Version)
				UNION ALL
				SELECT	Template_Group.Template_Group_Guid,  
						Template_Version.Template_Guid,
						Template_Version.FeatureFlags
				FROM	Template_Group
						INNER JOIN Template_Version ON Template_Group.Layout_Guid = Template_Version.Template_Guid
								AND Template_Group.Layout_Version = Template_Version.Template_Version
			) Layout ON Content.Template_Group_Guid = Layout.Template_Group_Guid
) as t
WHERE	t.Template_Group_Guid = Template_Group.Template_Group_Guid
GO
ALTER PROCEDURE [dbo].[spProject_UpdateDefinition] (
	@Xtf xml,
	@TemplateGuid uniqueidentifier,
	@EncryptedXtf varbinary(MAX)
)
AS
	DECLARE @FeatureFlags int;
	DECLARE @DataObjectGuid uniqueidentifier;
	DECLARE @XtfVersion nvarchar(10)

	BEGIN TRAN
		-- Feature detection --
		SET @FeatureFlags = 0
		SELECT @XtfVersion = Template.Template_Version FROM Template WHERE Template.Template_Guid = @TemplateGuid

		-- Workflow
		IF EXISTS(SELECT 1 FROM @Xtf.nodes('(/Intelledox_TemplateFile/Workflow/State/Transition)') as ProjectXML(P))
		BEGIN
			--Looking for a specified transition from the start state
			IF EXISTS(SELECT 1 FROM @Xtf.nodes('(/Intelledox_TemplateFile/Workflow/State)') as StateXML(S)
					  CROSS APPLY S.nodes('(Transition)') as TransitionXML(T)
					  WHERE S.value('@ID', 'uniqueidentifier') = '11111111-1111-1111-1111-111111111111'
					  AND (T.value('@SendToType', 'int') = 0 or T.value('@SendToType', 'int') IS NULL))
			BEGIN
				SET @FeatureFlags = @FeatureFlags | 256;
			END
			ELSE
			BEGIN
				SET @FeatureFlags = @FeatureFlags | 1;
			END
		END

		-- Data source
		IF EXISTS(SELECT 1 FROM @Xtf.nodes('(/Intelledox_TemplateFile/WizardInfo/BookmarkGroup)') as ProjectXML(P)
						CROSS APPLY P.nodes('(Question)') as QuestionXML(Q)
				WHERE	Q.value('@TypeId', 'int') = 2		-- Data field
						OR Q.value('@TypeId', 'int') = 9	-- Data table
						OR Q.value('@TypeId', 'int') = 12	-- Data list
						OR Q.value('@TypeId', 'int') = 14)	-- Data source
		BEGIN
			SET @FeatureFlags = @FeatureFlags | 2;

			INSERT INTO Xtf_Datasource_Dependency(Template_Guid, Template_Version, Data_Object_Guid)
			SELECT DISTINCT @TemplateGuid,
					@XtfVersion,
					Q.value('@DataObjectGuid', 'uniqueidentifier')
			FROM 
				@Xtf.nodes('(/Intelledox_TemplateFile/WizardInfo/BookmarkGroup/Question)') as QuestionXML(Q)
			WHERE Q.value('@DataObjectGuid', 'uniqueidentifier') is not null
				AND (SELECT  COUNT(*)
				FROM    Xtf_Datasource_Dependency 
				WHERE   Template_Guid = @TemplateGuid
				AND     Template_Version = @XtfVersion 
				AND		Data_Object_Guid = Q.value('@DataObjectGuid', 'uniqueidentifier')) = 0
			
		END

		-- Content library
		IF EXISTS(SELECT 1 FROM @Xtf.nodes('(/Intelledox_TemplateFile/WizardInfo/BookmarkGroup)') as ProjectXML(P)
						CROSS APPLY P.nodes('(Question)') as QuestionXML(Q)
				WHERE	Q.value('@TypeId', 'int') = 11
						AND Q.value('@DisplayType', 'int') = 8) -- Existing content item
		BEGIN
			SET @FeatureFlags = @FeatureFlags | 4;
		END
		
		IF EXISTS(SELECT 1 FROM @Xtf.nodes('(/Intelledox_TemplateFile/WizardInfo/BookmarkGroup)') as ProjectXML(P)
						CROSS APPLY P.nodes('(Question)') as QuestionXML(Q)
				WHERE	Q.value('@TypeId', 'int') = 11
						AND Q.value('@DisplayType', 'int') = 4) -- Search
		BEGIN
			SET @FeatureFlags = @FeatureFlags | 8;
		END

		BEGIN

		CREATE TABLE #ContentQuestionExisting
		(
			Id int identity(1,1),
			TemplateGuid uniqueidentifier,
			TemplateVersion nvarchar(10),
			ContentObjectGuid uniqueidentifier
		);

		INSERT INTO #ContentQuestionExisting(TemplateGuid, TemplateVersion, ContentObjectGuid)
		SELECT @TemplateGuid,
			   @XtfVersion,
			   C.value('@Id', 'uniqueidentifier')
		FROM @Xtf.nodes('(/Intelledox_TemplateFile/WizardInfo/BookmarkGroup/Question/Answer/ContentItem)') as ContentItemXML(C)
			

		INSERT INTO #ContentQuestionExisting(TemplateGuid, TemplateVersion, ContentObjectGuid)
		SELECT @TemplateGuid,
			   @XtfVersion,
			   Q.value('@ContentItemGuid', 'uniqueidentifier')
		FROM @Xtf.nodes('(/Intelledox_TemplateFile/WizardInfo/BookmarkGroup/Question)') as QuestionXML(Q)
		WHERE Q.value('@ContentItemGuid', 'uniqueidentifier') is not null
			
		INSERT INTO Xtf_ContentLibrary_Dependency(Template_Guid, Template_Version, Content_Object_Guid)
		SELECT r.TemplateGuid,
				r.TemplateVersion,
				r.ContentObjectGuid
		FROM #ContentQuestionExisting r
		WHERE NOT EXISTS (
			SELECT 1
			FROM Xtf_ContentLibrary_Dependency
			WHERE Xtf_ContentLibrary_Dependency.Content_Object_Guid = r.ContentObjectGuid AND
				  Xtf_ContentLibrary_Dependency.Template_Guid = r.TemplateGuid AND
				  Xtf_ContentLibrary_Dependency.Template_Version = r.TemplateVersion
		)
		GROUP BY r.ContentObjectGuid, r.TemplateGuid, r.TemplateVersion

		DROP TABLE #ContentQuestionExisting

		END

		-- Address
		IF EXISTS(SELECT 1 FROM @Xtf.nodes('(/Intelledox_TemplateFile/WizardInfo/BookmarkGroup)') as ProjectXML(P)
						CROSS APPLY P.nodes('(Question)') as QuestionXML(Q)
				WHERE	Q.value('@TypeId', 'int') = 1)
		BEGIN
			SET @FeatureFlags = @FeatureFlags | 16;
		END

		-- Rich text
		IF EXISTS(SELECT 1 FROM @Xtf.nodes('(/Intelledox_TemplateFile/WizardInfo/BookmarkGroup)') as ProjectXML(P)
						CROSS APPLY P.nodes('(Question)') as QuestionXML(Q)
				WHERE	Q.value('@TypeId', 'int') = 19)
		BEGIN
			SET @FeatureFlags = @FeatureFlags | 64;
		END
			
		-- Custom Question
		IF EXISTS(SELECT 1 FROM @Xtf.nodes('(/Intelledox_TemplateFile/WizardInfo/BookmarkGroup)') as ProjectXML(P)
						CROSS APPLY P.nodes('(Question)') as QuestionXML(Q)
				WHERE	Q.value('@TypeId', 'int') = 22)
		BEGIN
			SET @FeatureFlags = @FeatureFlags | 128;
		END
					
		IF @EncryptedXtf IS NULL
		BEGIN
			UPDATE	Template 
			SET		Project_Definition = @XTF,
					FeatureFlags = @FeatureFlags,
					EncryptedProjectDefinition = NULL
			WHERE	Template_Guid = @TemplateGuid;
		END
		ELSE
		BEGIN
			UPDATE	Template 
			SET		EncryptedProjectDefinition = @EncryptedXtf,
					FeatureFlags = @FeatureFlags,
					Project_Definition = NULL
			WHERE	Template_Guid = @TemplateGuid;
		END

		EXEC spProjectGroup_UpdateFeatureFlags @ProjectGuid=@TemplateGuid;
	COMMIT
	GO

CREATE PROCEDURE [dbo].[spSync_LibraryText] (
	@ContentData_Guid as uniqueidentifier,
	@ContentData as nvarchar(max),
	@ContentDataVersion as nvarchar(10),
	@Modified_Date as DateTime,
	@Modified_By as uniqueidentifier
)
AS
	IF EXISTS(SELECT ContentData_Guid FROM ContentData_Text WHERE ContentData_Guid = @ContentData_Guid)
	BEGIN			
		UPDATE	ContentData_Text
		SET		ContentData = @ContentData,
				ContentData_Version = @ContentDataVersion,
				Modified_Date = @Modified_Date,
				Modified_By = @Modified_By
		WHERE	ContentData_Guid = @ContentData_Guid
	END
	ELSE
	BEGIN
		INSERT INTO ContentData_Text(ContentData_Guid, ContentData, ContentData_Version, Modified_Date, Modified_By)
		VALUES (@ContentData_Guid, @ContentData, @ContentDataVersion, @Modified_Date, @Modified_By)
	END
GO

CREATE PROCEDURE [dbo].[spSync_LibraryVersionText] (
	@ContentData_Guid as uniqueidentifier,
	@ContentData as nvarchar(max),
	@ContentDataVersion as nvarchar(10),
	@Modified_Date as DateTime,
	@Modified_By as uniqueidentifier,
	@Approved as integer
)
AS
	IF EXISTS(SELECT ContentData_Guid FROM ContentData_Text_Version WHERE ContentData_Guid = @ContentData_Guid AND ContentData_Version = @ContentDataVersion)
	BEGIN			
		UPDATE	ContentData_Text_Version
		SET		ContentData = @ContentData,
				Modified_Date = @Modified_Date,
				Modified_By = @Modified_By,
				Approved = @Approved
		WHERE	ContentData_Guid = @ContentData_Guid AND ContentData_Version = @ContentDataVersion
	END
	ELSE
	BEGIN
		INSERT INTO ContentData_Text_Version(ContentData_Guid, ContentData, ContentData_Version, Modified_Date, Modified_By, Approved)
		VALUES (@ContentData_Guid, @ContentData, @ContentDataVersion, @Modified_Date, @Modified_By, @Approved)
	END

GO

CREATE PROCEDURE [dbo].[spSync_LibraryBinary] (
	@ContentData_Guid as uniqueidentifier,
	@ContentData as varbinary(max),
	@FileType as varchar(5),
	@ContentDataVersion as nvarchar(10),
	@Modified_Date as DateTime,
	@Modified_By as uniqueidentifier
)
AS
	IF EXISTS(SELECT ContentData_Guid FROM ContentData_Binary WHERE ContentData_Guid = @ContentData_Guid)
	BEGIN			
		UPDATE	ContentData_Binary
		SET		ContentData = @ContentData,
				FileType = @FileType,
				ContentData_Version = @ContentDataVersion,
				Modified_Date = @Modified_Date,
				Modified_By = @Modified_By
		WHERE	ContentData_Guid = @ContentData_Guid
	END
	ELSE
	BEGIN
		INSERT INTO ContentData_Binary(ContentData_Guid, ContentData, FileType, ContentData_Version, Modified_Date, Modified_By)
		VALUES (@ContentData_Guid, @ContentData, @FileType, @ContentDataVersion, @Modified_Date, @Modified_By)
	END
GO

CREATE PROCEDURE [dbo].[spSync_LibraryVersionBinary] (
	@ContentData_Guid as uniqueidentifier,
	@ContentData as varbinary(max),
	@FileType as varchar(5),
	@ContentDataVersion as nvarchar(10),
	@Modified_Date as DateTime,
	@Modified_By as uniqueidentifier,
	@Approved as integer
)
AS
	IF EXISTS(SELECT ContentData_Guid FROM ContentData_Binary_Version WHERE ContentData_Guid = @ContentData_Guid AND ContentData_Version = @ContentDataVersion)
	BEGIN			
		UPDATE	ContentData_Binary_Version
		SET		ContentData = @ContentData,
				FileType = @FileType,
				ContentData_Version = @ContentDataVersion,
				Modified_Date = @Modified_Date,
				Modified_By = @Modified_By
		WHERE	ContentData_Guid = @ContentData_Guid AND ContentData_Version = @ContentDataVersion
	END
	ELSE
	BEGIN
		INSERT INTO ContentData_Binary_Version(ContentData_Guid, ContentData, FileType, ContentData_Version, Modified_Date, Modified_By, Approved)
		VALUES (@ContentData_Guid, @ContentData, @FileType, @ContentDataVersion, @Modified_Date, @Modified_By, @Approved)
	END
GO

CREATE PROCEDURE [dbo].[spSynchronise_GetDataSourceDependencies] (
	@BusinessUnitGuid as uniqueidentifier
)
AS
	SELECT  Xtf_Datasource_Dependency.Template_Guid,
			Xtf_Datasource_Dependency.Template_Version,
			[Data_Object_Guid]
	FROM [dbo].[Xtf_Datasource_Dependency]
	inner join Template ON Template.Template_Guid = Xtf_Datasource_Dependency.Template_Guid
	WHERE Template.Business_Unit_GUID = @BusinessUnitGuid
GO

CREATE PROCEDURE [dbo].[spSynchronise_UpdateDataSourceDependency] (
	@TemplateGuid as uniqueidentifier,
	@TemplateVersion as nvarchar(10),
	@DataObjectGuid as uniqueidentifier
)
AS
	IF NOT EXISTS(SELECT Template_Guid FROM Xtf_Datasource_Dependency WHERE Template_Guid = @TemplateGuid AND Template_Version = @TemplateVersion AND Data_Object_Guid = @DataObjectGuid)
	BEGIN
		INSERT INTO Xtf_Datasource_Dependency(Template_Guid, Template_Version, Data_Object_Guid)
		VALUES (@TemplateGuid, @TemplateVersion, @DataObjectGuid)
	END
GO


CREATE PROCEDURE [dbo].[spSynchronise_GetContentLibraryDependencies] (
	@BusinessUnitGuid as uniqueidentifier
)
AS
	SELECT  Xtf_ContentLibrary_Dependency.Template_Guid,
			Xtf_ContentLibrary_Dependency.Template_Version,
			[Content_Object_Guid]
	FROM [dbo].[Xtf_ContentLibrary_Dependency]
	inner join Template ON Template.Template_Guid = Xtf_ContentLibrary_Dependency.Template_Guid
	WHERE Template.Business_Unit_GUID = @BusinessUnitGuid
GO

CREATE PROCEDURE [dbo].[spSynchronise_UpdateContentLibraryDependency] (
	@TemplateGuid as uniqueidentifier,
	@TemplateVersion as nvarchar(10),
	@ContentObjectGuid as uniqueidentifier
)
AS
	IF NOT EXISTS(SELECT Template_Guid FROM Xtf_ContentLibrary_Dependency WHERE Template_Guid = @TemplateGuid AND Template_Version = @TemplateVersion AND Content_Object_Guid = @ContentObjectGuid)
	BEGIN
		INSERT INTO Xtf_ContentLibrary_Dependency(Template_Guid, Template_Version, Content_Object_Guid)
		VALUES (@TemplateGuid, @TemplateVersion, @ContentObjectGuid)
	END
GO

CREATE PROCEDURE [dbo].[spSync_TemplateGrpCategory]
	@BusinessUnitGuid uniqueidentifier,
	@CategoryID int,
	@Name nvarchar(100)
AS

	IF EXISTS(SELECT Category_ID FROM Category WHERE Category_ID = @CategoryID)
	BEGIN
		UPDATE Category
		SET Name = @Name
		WHERE Category_ID = @CategoryID
	END
	ELSE
	BEGIN
		SET IDENTITY_INSERT Category ON

		INSERT INTO Category (Category_ID, BusinessUnitGuid, [Name]) 
		VALUES (@CategoryID, @BusinessUnitGuid, @Name);

		SET IDENTITY_INSERT Category OFF
	END
GO

ALTER procedure [dbo].[spTemplate_TemplateList]
	@TemplateGuid uniqueidentifier,
	@ErrorCode int output
AS
	SET NOCOUNT ON
	
	SELECT	a.template_id, a.[name] as template_name, a.template_type_id, a.fax_template_id, 
			a.template_guid, a.Supplier_Guid, a.Business_Unit_Guid,
			a.Content_Bookmark, a.HelpText, a.Modified_Date, Intelledox_User.Username,
			a.[name] as Project_Name, a.Modified_By, lockedByUser.Username AS LockedBy, a.Comment, 
			a.Template_Version, a.FeatureFlags, a.IsMajorVersion
	FROM	Template a
			LEFT JOIN Intelledox_User ON Intelledox_User.User_Guid = a.Modified_By
			LEFT JOIN Intelledox_User lockedByUser ON lockedByUser.User_Guid = a.LockedByUserGuid
	WHERE	a.Template_Guid = @TemplateGuid;

	set @ErrorCode = @@error;
GO

CREATE PROCEDURE [dbo].[spSync_Project]
	@TemplateID int,
	@Name nvarchar(100),
	@TemplateTypeID int,
	@FaxTemplateID int,
	@ContentBookmark nvarchar(100),
	@TemplateGuid uniqueidentifier,
	@TemplateVersion nvarchar(10),
	@ImportDate datetime,
	@HelpText nvarchar(4000),
	@BusinessUnitGuid uniqueidentifier,
	@SupplierGuid uniqueidentifier,
	@ProjectDefinition xml,
	@ModifiedDate datetime,
	@ModifiedBy uniqueidentifier,
	@Comment nvarchar(max),
	@LockedByUserGuid uniqueidentifier,
	@IsMajorVersion bit,
	@FeatureFlags int,
	@EncryptedProjectDefinition varbinary(max) 
AS
BEGIN TRAN

	IF NOT EXISTS(SELECT Template_ID FROM Template WHERE Template_Guid = @TemplateGuid)
	BEGIN
		SET IDENTITY_INSERT Template ON
		INSERT INTO Template (Template_ID,Name,Template_Type_ID,
			Fax_Template_ID,content_bookmark,Template_Guid,Template_Version,
			Import_Date,HelpText,Business_Unit_GUID,Supplier_Guid,Project_Definition,Modified_Date,Modified_By,
			Comment,LockedByUserGuid,IsMajorVersion,FeatureFlags,EncryptedProjectDefinition)
		VALUES (@TemplateID,
				@Name,
				@TemplateTypeID,
				@FaxTemplateID,
				@ContentBookmark,
				@TemplateGuid,
				@TemplateVersion,
				@ImportDate,
				@HelpText,
				@BusinessUnitGuid,
				@SupplierGuid,
				@ProjectDefinition,
				@ModifiedDate,
				@ModifiedBy,
				@Comment,
				@LockedByUserGuid,
				@IsMajorVersion,
				@FeatureFlags,
				@EncryptedProjectDefinition)
			
		SET IDENTITY_INSERT Template OFF
	END
	ELSE
	BEGIN
		UPDATE Template
		SET Name = @Name,
			Template_Type_ID = @TemplateTypeID,
			Fax_Template_ID = @FaxTemplateID,
			content_bookmark = @ContentBookmark,
			Template_Version = @TemplateVersion,
			Import_Date = @ImportDate,
			HelpText = @HelpText,
			Supplier_Guid = @SupplierGuid,
			Project_Definition = @ProjectDefinition,
			Modified_Date = @ModifiedDate,
			Modified_By = @ModifiedBy,
			Comment = @Comment,
			LockedByUserGuid = @LockedByUserGuid,
			IsMajorVersion = @IsMajorVersion,
			FeatureFlags = @FeatureFlags,
			EncryptedProjectDefinition = @EncryptedProjectDefinition
		WHERE Template_Guid = @TemplateGuid
	END
COMMIT TRAN
GO


ALTER VIEW [dbo].[vwTemplateVersion]
AS
	SELECT	Template_Version.Template_Version, 
			Template_Version.Template_Guid,
			Template_Version.Modified_Date,
			Template_Version.Modified_By,
			Template_Version.Comment,
			Template.Template_Type_ID,
			Template.LockedByUserGuid,
			Template_Version.IsMajorVersion,
			Template_Version.FeatureFlags,
			Intelledox_User.Username,
			Address_Book.First_Name + ' ' + Address_Book.Last_Name AS Full_Name,
			CASE (SELECT COUNT(*)
					FROM Template_Group 
					WHERE (Template_Group.Template_Guid = Template_Version.Template_Guid
								AND Template_Group.Template_Version = Template_Version.Template_Version)
							OR (Template_Group.Layout_Guid = Template_Version.Template_Guid
								AND Template_Group.Layout_Version = Template_Version.Template_Version)) 
				WHEN 0
				THEN 0
				ELSE 1
			END AS InUse,
			0 AS Latest
		FROM	Template_Version
			INNER JOIN Template ON Template_Version.Template_Guid = Template.Template_Guid
			LEFT JOIN Intelledox_User ON Intelledox_User.User_Guid = Template_Version.Modified_By
			LEFT JOIN Address_Book ON Intelledox_User.Address_ID = Address_Book.Address_ID
	UNION ALL
		SELECT	Template.Template_Version, 
				Template.Template_Guid,
				Template.Modified_Date,
				Template.Modified_By,
				Template.Comment,
				Template.Template_Type_ID,
				Template.LockedByUserGuid,
				Template.IsMajorVersion,
				Template.FeatureFlags,
				Intelledox_User.Username,
				Address_Book.First_Name + ' ' + Address_Book.Last_Name AS Full_Name,
				CASE (SELECT COUNT(*)
						FROM Template_Group 
						WHERE (Template_Group.Template_Guid = Template.Template_Guid
									AND (Template_Group.Template_Version = Template.Template_Version OR ISNULL(Template_Group.Template_Version, '0') = '0'))
							OR (Template_Group.Layout_Guid = Template.Template_Guid
									AND (Template_Group.Layout_Version = Template.Template_Version OR ISNULL(Template_Group.Layout_Version, '0') = '0')))
					WHEN 0
					THEN 0
					ELSE 1
				END AS InUse,
				1 AS Latest
		FROM	Template
			LEFT JOIN Intelledox_User ON Intelledox_User.User_Guid = Template.Modified_By
			LEFT JOIN Address_Book ON Intelledox_User.Address_ID = Address_Book.Address_ID;

GO

ALTER procedure [dbo].[spProject_GetProjectVersions]
	@ProjectGuid uniqueidentifier
as
		SELECT vwTemplateVersion.Template_Version, 
			vwTemplateVersion.Template_Guid,
			vwTemplateVersion.Modified_Date,
			vwTemplateVersion.Modified_By,
			vwTemplateVersion.Username,
			ISNULL(vwTemplateVersion.Full_Name, '') AS Full_Name,
			vwTemplateVersion.Comment,
			vwTemplateVersion.LockedByUserGuid,
			vwTemplateVersion.FeatureFlags,
			vwTemplateVersion.IsMajorVersion,
			vwTemplateVersion.InUse
		FROM	vwTemplateVersion
		WHERE	vwTemplateVersion.Template_Guid = @ProjectGuid
	ORDER BY Modified_Date DESC;
GO

CREATE procedure [dbo].[spSync_ProjectVersion]
	@TemplateVersion nvarchar(10),
      @TemplateGuid uniqueidentifier,
      @ModifiedDate datetime,
      @ModifiedBy uniqueidentifier,
      @ProjectDefinition xml,
      @Comment nvarchar(max),
      @IsMajorVersion bit,
      @FeatureFlags int,
      @EncryptedProjectDefinition varbinary(max)
as
	IF NOT EXISTS (Select Template_Version from Template_Version where Template_Guid = @TemplateGuid AND Template_Version = @TemplateVersion)
	BEGIN
		INSERT INTO Template_Version(Template_Version, Template_Guid, Modified_Date, Modified_By, 
					Project_Definition, Comment, IsMajorVersion, FeatureFlags, EncryptedProjectDefinition)
		VALUES(@TemplateVersion, @TemplateGuid, @ModifiedDate, @ModifiedBy,@ProjectDefinition,@Comment,
				@IsMajorVersion, @FeatureFlags, @EncryptedProjectDefinition)
	END
	ELSE
	BEGIN
		UPDATE Template_Version
		SET Modified_Date = @ModifiedDate,
			Modified_By = @ModifiedBy,
			Project_Definition = @ProjectDefinition,
			Comment = @Comment,
			IsMajorVersion = @IsMajorVersion,
			FeatureFlags = @FeatureFlags,
			EncryptedProjectDefinition = @EncryptedProjectDefinition
		WHERE Template_Guid = @TemplateGuid AND Template_Version = @TemplateVersion
	END
GO

CREATE PROCEDURE [dbo].[spSync_ProjectTemplateFileVersion]
	@TemplateGuid uniqueidentifier,
	@FileGuid uniqueidentifier,
	@Binary varbinary(max),
	@TemplateVersion nvarchar(10),
	@FormatTypeId varchar(6)
as

	IF NOT EXISTS(SELECT Template_Guid FROM Template_File_Version WHERE Template_Guid = @TemplateGuid AND Template_Version = @TemplateVersion AND File_Guid = @FileGuid)
	BEGIN
		INSERT INTO Template_File_Version(Template_Guid, File_Guid, [Binary], Template_Version, FormatTypeId)
		VALUES (@TemplateGuid, @FileGuid, @Binary, @TemplateVersion, @FormatTypeId)
	END
	ELSE
	BEGIN
		UPDATE Template_File_Version
		SET File_Guid = @FileGuid,
			[Binary] = @Binary,
			FormatTypeId = @FormatTypeId
		WHERE Template_Guid = @TemplateGuid AND Template_Version = @TemplateVersion AND File_Guid = @FileGuid
	END
GO

ALTER procedure [dbo].[spContent_UpdatePlaceholder]
	@ContentItemGuid uniqueidentifier,
	@Placeholder nvarchar(100),
	@TypeId int
AS
IF NOT EXISTS(Select ContentItemGuid from Content_Item_Placeholder where ContentItemGuid = @ContentItemGuid AND PlaceholderName = @Placeholder AND TypeId = @TypeId)
BEGIN
	INSERT INTO Content_Item_Placeholder(ContentItemGuid, PlaceholderName, TypeId)
	VALUES (@ContentItemGuid, @Placeholder, @TypeId);
END
GO

CREATE procedure [dbo].[spSync_UserIntoDeletedUser]
	@UserGuid uniqueidentifier,
	@Username nvarchar(256),
	@BusinessUnitGuid uniqueidentifier,
	@FirstName nvarchar(50),
	@LastName nvarchar(50),
	@Email nvarchar(256)
AS
	IF NOT EXISTS
		(Select UserGuid from Intelledox_UserDeleted where Intelledox_UserDeleted.UserGuid = @UserGuid
		Union 
		Select User_Guid from Intelledox_User where Intelledox_User.User_Guid = @UserGuid)
	BEGIN
		INSERT INTO Intelledox_UserDeleted(UserGuid, Username, BusinessUnitGuid, FirstName, LastName, Email)
		VALUES(@UserGuid, @Username, @BusinessUnitGuid, @FirstName, @LastName, @Email)
	END

GO
