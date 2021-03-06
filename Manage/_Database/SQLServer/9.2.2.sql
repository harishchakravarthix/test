truncate table dbversion;
go
insert into dbversion(dbversion) values ('9.2.2');
go

IF NOT EXISTS (SELECT * FROM sys.objects WHERE type = 'P' AND OBJECT_ID = OBJECT_ID('dbo.spProject_GetProjectVersionByPublishedByAndGroupGuid'))
   exec('CREATE PROCEDURE [dbo].[spProject_GetProjectVersionByPublishedByAndGroupGuid] AS BEGIN SET NOCOUNT ON; END')
GO

ALTER PROCEDURE [dbo].[spProject_GetProjectVersionByPublishedByAndGroupGuid] (
	@ProjectGroupGuid uniqueidentifier,
	@ProjectGuid uniqueidentifier,
	@PublishedBy datetime
)
AS
	SELECT	Template.Template_Version
		FROM	Template_Group,
				Template 
		WHERE	Template_Group.Template_Group_Guid = @ProjectGroupGuid
			AND Template.Template_Guid = @ProjectGuid
			AND (Template_Group.MatchProjectVersion = 0 
				OR Template.Modified_Date <= @PublishedBy)
	UNION ALL
		SELECT	Template_Version.Template_Version
		FROM	Template_Group,
				Template_Version
		WHERE	Template_Group.Template_Group_Guid = @ProjectGroupGuid
				AND Template_Version.Template_Guid = @ProjectGuid
				AND (Template_Group.MatchProjectVersion = 1 
						AND (Template_Version.Modified_Date > @PublishedBy
							AND Template_Version.Modified_Date = (SELECT TOP 1 VersionDate.Modified_Date
								FROM Template_Version VersionDate
								WHERE VersionDate.Template_Guid = Template_Version.Template_Guid
									AND VersionDate.Modified_Date <= @PublishedBy
								ORDER BY VersionDate.Modified_Date DESC)))
GO

CREATE PROCEDURE [dbo].[spProjectGroup_FolderListSearch]
	@UserGuid uniqueidentifier,
	@SearchTerm nvarchar(50)
AS
	DECLARE @BusinessUnitGuid uniqueidentifier
	
	SELECT	@BusinessUnitGuid = Business_Unit_Guid
	FROM	Intelledox_User
	WHERE	Intelledox_User.User_Guid = @UserGuid;

	SELECT	f.Folder_Name, tg.Template_Group_ID,
			tg.HelpText as TemplateGroup_HelpText, t.[Name] as Template_Name, 
			tg.Template_Group_Guid, tg.FeatureFlags
	FROM	Folder f
			INNER JOIN Template_Group tg on f.Folder_Guid = tg.Folder_Guid
			INNER JOIN Template t on tg.Template_Guid = t.Template_Guid
	WHERE	f.Business_Unit_GUID = @BusinessUnitGUID
			AND f.Folder_Guid IN (
				SELECT	Folder_Group.FolderGuid
				FROM	Folder_Group
						INNER JOIN User_Group_Subscription ON Folder_Group.GroupGuid = User_Group_Subscription.GroupGuid
				WHERE	User_Group_Subscription.UserGuid = @UserGuid
				)
			AND (f.Folder_Name COLLATE Latin1_General_CI_AI LIKE ('%' + @SearchTerm + '%') COLLATE Latin1_General_CI_AI
			     OR t.Name COLLATE Latin1_General_CI_AI LIKE ('%' + @SearchTerm + '%') COLLATE Latin1_General_CI_AI)
			AND (tg.EnforcePublishPeriod = 0 
				OR ((tg.PublishStartDate IS NULL OR tg.PublishStartDate < getdate())
					AND (tg.PublishFinishDate IS NULL OR tg.PublishFinishDate > getdate())))
	ORDER BY f.Folder_Name, t.[Name]

GO

ALTER PROCEDURE [dbo].[spTenant_ProvisionTenant] (
	   @NewBusinessUnit uniqueidentifier,
	   @AdminUserGuid uniqueidentifier,
       @TenantName nvarchar(200),
       @FirstName nvarchar(50),
       @LastName nvarchar(50),
       @UserName nvarchar(256),
       @UserPasswordHash varchar(1000),
       @UserPwdSalt nvarchar(128),
       @UserPwdFormat int,
       @Email nvarchar(256),
       @TenantKey varbinary(MAX),
       @TenantType int,
       @TenantImage image,
       @LicenseHolderName nvarchar(4000)
)
AS
       DECLARE @GuestUserGuid uniqueidentifier
       DECLARE @TenantGroupGuid uniqueidentifier
	   DECLARE @BusinessUnitIdentifier int

       SET @GuestUserGuid = NewID()
	   SET @BusinessUnitIdentifier = floor(rand(CONVERT([varbinary],newid(),(0)))*(89999))+(10000)

	   WHILE @BusinessUnitIdentifier IN (SELECT IdentifyBusinessUnit FROM Business_Unit)
	   BEGIN
		SET @BusinessUnitIdentifier = floor(rand(CONVERT([varbinary],newid(),(0)))*(89999))+(10000)
	   END
	   
       --New business unit (Company in SaaS)
       INSERT INTO Business_Unit(Business_Unit_Guid, Name, TenantKey, TenantType, IdentifyBusinessUnit)
       VALUES (@NewBusinessUnit, @TenantName, CONVERT(varbinary(MAX), @TenantKey), @TenantType, @BusinessUnitIdentifier)

		IF DATALENGTH(@TenantImage) > 0
		BEGIN
			UPDATE	Business_Unit
			SET		TenantLogo = @TenantImage
			WHERE	Business_Unit_Guid = @NewBusinessUnit
		END

       --Insert roles
       --End User
       --Workflow Administrator
       INSERT INTO Administrator_Level(AdminLevel_Description, RoleGuid, Business_Unit_Guid)
       VALUES ('End User', NewId(), @NewBusinessUnit)

       INSERT INTO Administrator_Level(AdminLevel_Description, RoleGuid, Business_Unit_Guid)
       VALUES ('Workflow Administrator', NewId(), @NewBusinessUnit)

       SET @TenantGroupGuid = NewId()
	   --Group address for User Group
       INSERT INTO Address_Book (Organisation_Name)
       VALUES (@TenantName + ' Users')

       --New group
       INSERT INTO User_Group(Name, WinNT_Group, Business_Unit_Guid, Group_Guid, AutoAssignment, SystemGroup, Address_ID)
       VALUES (@TenantName + ' Users', 0, @NewBusinessUnit, @TenantGroupGuid, 1, 1, @@IDENTITY)

	   --Mobile App Users Group
	   INSERT INTO Address_Book(Full_Name, Organisation_Name)
	   VALUES ('Mobile App Users', 'Mobile App Users');

	   INSERT INTO User_Group(Name, WinNT_Group, Business_Unit_Guid, Group_Guid, AutoAssignment, SystemGroup, Address_ID)
	   VALUES ('Mobile App Users', 0, @NewBusinessUnit, NewId(), 0, 1, @@IDENTITY);

		--call procedure for creating admin user, global administrator role, role mapping and group assignment
	   EXEC spTenant_CreateAdminUser @NewBusinessUnit, @AdminUserGuid, @FirstName, @LastName, @UserName, 
										@UserPasswordHash, @UserPwdSalt, @UserPwdFormat, @Email 

       --User address for guest user
       INSERT INTO address_book (full_name, first_name, last_name, email_address)
       VALUES (@LicenseHolderName + '_Guest', '', '', '')
       --Guest
       INSERT INTO Intelledox_User(Username, Pwdhash, PwdSalt, PwdFormat, WinNT_User, Business_Unit_Guid, User_Guid, Address_ID, IsGuest)
       VALUES (@LicenseHolderName + '_Guest', '', '', @UserPwdFormat, 0, @NewBusinessUnit, @GuestUserGuid, @@IDENTITY, 1)

       INSERT INTO User_Group_Subscription(UserGuid, GroupGuid, IsDefaultGroup)
       VALUES(@GuestUserGuid, @TenantGroupGuid, 1)

       INSERT INTO Global_Options(BusinessUnitGuid, OptionCode, OptionDescription, OptionValue)
       SELECT @NewBusinessUnit, OptionCode, OptionDescription, OptionValue
       FROM   Global_Options
       WHERE  BusinessUnitGuid = (SELECT OptionValue
									FROM Global_Options
									WHERE UPPER(OptionCode) = 'DEFAULT_TENANT');

       UPDATE Global_Options
       SET OptionValue='DoNotReply@intelledox.com'
       WHERE BusinessUnitGuid = @NewBusinessUnit AND OptionCode='FROM_EMAIL_ADDRESS';

	   --sync the license holder name to tenant name
       UPDATE Global_Options
       SET OptionValue=@LicenseHolderName
       WHERE BusinessUnitGuid = @NewBusinessUnit AND OptionCode='LICENSE_HOLDER';
GO

ALTER procedure [dbo].[spDataSource_HasAccess]
	@DataObjectGuid uniqueidentifier,
	@UserGuid uniqueidentifier,
	@BusinessUnitGuid uniqueidentifier
AS
	SET ARITHABORT ON 

	;WITH dataObjectDependency (Template_Guid)
	AS
	(
	--Select all the projects AND fragments that contain a reference to the data object
	SELECT	dsDependency.Template_Guid
	FROM	Xtf_Datasource_Dependency dsDependency
	WHERE dsDependency.Data_Object_Guid = @DataObjectGuid
	UNION ALL
	--Add any content projects to the list that reference the FRAGMENTS that were identified above
	SELECT fDependency.Template_Guid
	FROM Xtf_Fragment_Dependency fDependency
		 INNER JOIN dataObjectDependency ON fDependency.Fragment_Guid = dataObjectDependency.Template_Guid
	) 

	SELECT 	TOP 1
	1
	FROM Template
		 INNER JOIN dataObjectDependency on dataObjectDependency.Template_Guid = Template.Template_Guid
		 INNER JOIN Template_Group ON Template_Group.Template_Guid = Template.Template_Guid
	 			                      OR Template_Group.Layout_Guid = Template.Template_Guid
		 INNER JOIN Folder_Group ON Folder_Group.FolderGuid = Template_Group.Folder_Guid
		 INNER JOIN User_Group_Subscription ON User_Group_Subscription.GroupGuid = Folder_Group.GroupGuid
	WHERE	
		Template.Business_Unit_GUID = @BusinessUnitGuid
		AND (User_Group_Subscription.UserGuid = @UserGuid
			 OR (Template_Group.Template_Group_Guid IN (SELECT ActionList.ProjectGroupGuid 
														FROM ActionListState 
		                                                INNER JOIN ActionList ON ActionList.ActionListId = ActionListState.ActionListId
		                                                WHERE ActionListState.IsComplete = 0 
													    AND (ActionListState.AssignedGuid = @UserGuid OR ActionListState.LockedByUserGuid =  @UserGuid))
														))

GO

