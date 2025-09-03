USE [TA]
GO
/****** Object:  StoredProcedure [liquidity_exec].[usp_Calculate_LCR_daily]    Script Date: 9/3/2025 2:20:23 PM ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
	--

ALTER PROCEDURE [liquidity_exec].[usp_Calculate_LCR_daily]   

	@EffectiveDate			date		=	null
,	@MonthEnd				bit			=	null	
--
,	@Mode					varchar(4)	=	'VIEW'		--	'VIEW' , 'TEMP' 
--
,	@DEBUG					bit			=	1		
--	
--WITH EXECUTE AS OWNER	--	2018-08-07 :: necessary ? only for MBS repo sub-procedure ? 
-- 
AS	
/**************************************************************************************

	Gathers input data for LCR (Liquidity Coverage Ratio) calculation 
		and computes results as of provided @EffectiveDate and @MonthEnd parameters.	

		
		Example:	


			EXEC	liquidity_exec.usp_Calculate_LCR_daily 		
						@EffectiveDate			=	'2024-09-30'	
					,	@MonthEnd				=	1		
					--	
					,	@Mode					=	'VIEW'		
					--	
					,	@DEBUG					=	1		
					--	
			 ;			


	Date			Action	
	----------		----------------------------
	2024-09-16		Created initial version.  
	2025-01-02		Commented out section where @MonthEnd is automatically set to 1 for month-end dates.
	2025-01-08		Added FHSA columns to report_exec.usp_RelationshipBalances_LCR temp table.
	2025-01-20		Added manually warning to selected NULL LCR Numbers.
	2025-03-31		Adjusted for Registered Promo case
	2025-04-24		Adjusted MaturityDate for one Covered Bond.
	2025-05-05		Changed from < to <= to cover case when balance = 100000.
	2025-06-03		Adjusted Concentra Mortgage Commitment business date.
	2025-07-16		Update fpr Concentra Deposits

**************************************************************************************/	
BEGIN
	SET NOCOUNT ON;

	--
	--

	DECLARE		@ErrorMessage				varchar(500)	
	,			@RowCount					int				
	--
	,			@ProcedureReturnValue		int											
	--
	,			@CurrentTimestamp			datetime		=	getdate()	
	--										
	--	
	,			@YearNumber					int		
	,			@MonthNumber				int		
	--
	--
	,			@BusinessDayCalendar_Name	varchar(50)		=	'Toronto (Bank)'	
	--		
	--	
	,			@DigitalSavings_MaxBusinessDate		date			
	,			@BrokeredHISA_MaxTradeDate			date	
	--
	--	
	,			@LegalEntity_ShortName_TD		varchar(30)		=	'BMO'	
	--	
	--
	,			@OSFI_NewTemplate_EffectiveDate				date			=	'2020-02-01'

	,		    @RunDate  date

	,           @LatestMonthEndAvailable     date
	,			@NULL_Message_EQB  varchar(500) = 'Lists of EQB LCR Numbers are NULL : '
	,			@NULL_Message_Concentra  varchar(500) = 'Lists of Concentra LCR Numbers are NULL : '
	--
	--	
	;	

	IF OBJECT_ID('tempdb..#lcr_EQB_DepositNoteMaturities') IS NOT NULL DROP TABLE #lcr_EQB_DepositNoteMaturities
	IF OBJECT_ID('tempdb..#lcr_EQB_LiquidityPortfolio') IS NOT NULL DROP TABLE #lcr_EQB_LiquidityPortfolio

	IF OBJECT_ID('tempdb..#lcr_EQB_UndisbursedCommitments') IS NOT NULL DROP TABLE #lcr_EQB_UndisbursedCommitments
	IF OBJECT_ID('tempdb..#lcr_EQB_LargestNetCollateralFlow') IS NOT NULL DROP TABLE #lcr_EQB_LargestNetCollateralFlow
	--	
	IF OBJECT_ID('tempdb..#lcr_STAGING_LineItem_Value_EQB') IS NOT NULL DROP TABLE #lcr_STAGING_LineItem_Value_EQB
	IF OBJECT_ID('tempdb..#lcr_STAGING_LineItem_Value_Concentra') IS NOT NULL DROP TABLE #lcr_STAGING_LineItem_Value_Concentra

	IF OBJECT_ID('tempdb..#lcr_Concentra_Mgt_Commitment') IS NOT NULL DROP TABLE #lcr_Concentra_Mgt_Commitment
	IF OBJECT_ID('tempdb..#lcr_Concentra_Mgt_Inflow') IS NOT NULL DROP TABLE #lcr_Concentra_Mgt_Inflow
	IF OBJECT_ID('tempdb..#lcr_Concentra_Derivative_Cashflow') IS NOT NULL DROP TABLE #lcr_Concentra_Derivative_Cashflow
	--
	IF OBJECT_ID('tempdb..#lcr_Concentra_Deposits') IS NOT NULL DROP TABLE #lcr_Concentra_Deposits
	IF OBJECT_ID('tempdb..#lcr_EQB_Deposits') IS NOT NULL DROP TABLE #lcr_EQB_Deposits
	IF OBJECT_ID('tempdb..#lcr_EQB_Mortgage_Inflows') IS NOT NULL DROP TABLE #lcr_EQB_Mortgage_Inflows
	IF OBJECT_ID('tempdb..#lcr_EQB_Securitization_Cashflows') IS NOT NULL DROP TABLE #lcr_EQB_Securitization_Cashflows
	IF OBJECT_ID('tempdb..#lcr_EQB_Securitization_Loan_Maturities') IS NOT NULL DROP TABLE #lcr_EQB_Securitization_Loan_Maturities
	IF OBJECT_ID('tempdb..#lcr_Check_NULL_EQB') IS NOT NULL DROP TABLE #lcr_Check_NULL_EQB
	IF OBJECT_ID('tempdb..#lcr_Check_NULL_Concentra') IS NOT NULL DROP TABLE #lcr_Check_NULL_Concentra
	
	--
	--
	
	IF @Mode IS NULL 
	BEGIN 
		SET @Mode = 'VIEW'	
	END		

	IF @Mode NOT IN ( 'VIEW' , 'TEMP' )		
	BEGIN 
		SET @ErrorMessage = 'The provided @Mode value is unexpected. Acceptable values are ''VIEW'' and ''TEMP''.' 
		GOTO ERROR 
	END		
	
	--
	--	
	
	IF @Mode = 'TEMP' 
	BEGIN 
		--
		--	check that the required input temp table exists 
		--	
		IF OBJECT_ID( 'tempdb..#usp_Calculate_LCR_Output' ) IS NULL 
		BEGIN 
			SET @ErrorMessage = 'For @Mode = ''TEMP'', you must create a table #usp_Calculate_LCR_Output before executing procedure.' 
			GOTO ERROR	
		END				

		--
		--	check that the required input temp table is empty 
		--	
		IF ( SELECT COUNT(*) FROM #usp_Calculate_LCR_Output ) > 0 
		--
		--
		--AND coalesce(@AllowNonEmptyInputTable,0) = 0 
		--
		--
		BEGIN 
			SET @ErrorMessage = 'The result table #usp_Calculate_LCR_Output must be empty.' 
			GOTO ERROR 
		END 

		--
		--	check format of required input temp table 
		--	
		BEGIN TRY 

			INSERT INTO #usp_Calculate_LCR_Output   
			(
				RunTimestamp,				
			--								
				EffectiveDate,
				MonthEnd,
				LCR_EQBLineItem_Number,
				EQB_Value,
				Concentra_Value,
				LCR_EQBLineItem_Note,
				EQB_Value_Thousands,
				Concentra_Value_Thousands
			

			--						
			)	

			SELECT	X.RunTimestamp,				
			--								
					X.EffectiveDate,
					X.MonthEnd,
					X.LCR_EQBLineItem_Number,
					X.EQB_Value,
					X.Concentra_Value,
					X.LCR_EQBLineItem_Note,
					X.EQB_Value_Thousands,
					X.Concentra_Value_Thousands				
			--
			FROM	(
						VALUES	( 'Mar 12, 2018 14:17:00.000'	
								--	
								, 'Nov 5, 2018' 		
								, 0						
								--								
								, 77
								--								
								, 777.77 
								, 888.88
								, 'example'			
								--								
								, 0.77777
								, 0.88888
								--			
								)
					)	
						X	(	
								RunTimestamp,				
							--								
								EffectiveDate,
								MonthEnd,
								LCR_EQBLineItem_Number,
								EQB_Value,
								Concentra_Value,
								LCR_EQBLineItem_Note,
								EQB_Value_Thousands,
								Concentra_Value_Thousands				
							--							
							)	
			--	
			WHERE	1 = 0	
			--	
			;	

		END TRY 
		BEGIN CATCH 

			SET @ErrorMessage = 'The format of #usp_Calculate_LCR_Output is unexpected.' 
			GOTO ERROR 

		END CATCH	

	END		

	--	
	CREATE TABLE #lcr_EQB_DepositNoteMaturities 		
	(
		ID				int		not null	identity(1,1)	primary key		
	--
	,	DepositNoteID	int		not null
	,	EffectiveDate	date	null
	,	IssueDate		date	null
	,	Name			varchar(50)	null
	,	Currency		varchar(3)	null
	,	MaturityDate	date	null
	,	FaceValue		float	null
	,	Price			float	null
	,	MonthEnd		bit		null
	,	PaymentIn30Days	int		null
	,	PrincipalPaymentIn30Days	float	null
	,	InterestPaymentIn30Days		float	null
	--
	,	UNIQUE	( DepositNoteID )	
	--	
	)	
	--	
	;	

	CREATE TABLE #lcr_EQB_LiquidityPortfolio	
	(
		ID		int		not null	identity(1,1)	primary key		
	--
	,	Category					varchar(40)		not	null	
	,	Subcategory					varchar(40)		not null		
	,	Instrument_Issuer			varchar(200)	null		--	2024-09-04	Added column
	,	LineItem					varchar(200)	not null
	--
	,	CouponRate					float			null
	,	MinSettlementDate			date			null
	,	MaturityDate				date			null
	,	FaceAmount					float			not null
	,	RemainingPrincipal			float			null	
	,	MarketValue					float			not null	
	,	BookCost					float			null
	,	PoolFactor					float			null
	,	PoolNumber_Numeric			int				null
	,	CUSIP						varchar(10)		null
	,	IsRedeemable				float			null
	,	RedeemableDate				date			null

	,	BondType_ShortName			varchar(20)		null	
	--
	--
	,	IsFinancial					bit				null	
	,	Rating_SP					varchar(10)		null
	,	RatingDate					date			null
	,	AccruedInterest				float			null
	,	MktValPlusAccrued			float			null
	,	IsPRA						bit				null

	--
	,	UNIQUE	( Category , Subcategory , LineItem , CouponRate)	
	--	
	)	
	--
	;	

	CREATE TABLE #lcr_Concentra_LiquidityPortfolio	
	( 
		ID		int		not null	identity(1,1)	primary key		
	--
	,	Category					varchar(40)		not	null	
	,	Subcategory					varchar(40)		not null	
	,	LineItem					varchar(200)	 null	
	,	Issuer_LegalEntity_ShortName	varchar(200)	null		--	2024-09-06
	--
	,	PoolNumber_Numeric			int				null	
	,	BondType_ShortName			varchar(20)		null	
	--
	,	MaturityDate				date			null	
	,	FaceAmount					float			not null	
	,	RemainingPrincipal			float			null	
	,	MarketValue					float			not null	
	,	BookCost					float			null	
	--
	,	Rating_SP					varchar(10)		null	
	--
	,	CollateralType				varchar(200)	null
	,	MinSettlementDate			date			null
	--
	,	UNIQUE	( Category , Subcategory , LineItem, MinSettlementDate)	
	--	
	)	
	--
	;
	--
	--
	
	CREATE TABLE #lcr_STAGING_LineItem_Value_EQB
	(
		ID							int		not null	identity(1,1)	primary key		
	--
	,	LCR_EQBLineItem_Number		int		not null	unique		
	,	[Value]						float	null				
	--	
	)	
	--
	;	

	CREATE TABLE #lcr_STAGING_LineItem_Value_Concentra
	(
		ID							int		not null	identity(1,1)	primary key		
	--
	,	LCR_EQBLineItem_Number		int		not null	unique		
	,	[Value]						float	null				
	--	
	)	
	--
	;

	--
	--
	CREATE TABLE #lcr_Concentra_Deposits  
	(
		ID						int				not null	identity(1,1)	primary key		
	,	SourceTable				varchar(35)		not null
	,	Category				varchar(40)		null
	,	Currency				varchar(5)		null
	,	DepositType				varchar(5)		null
	,	Payment					varchar(25)		null
	,	InsuredPrincipalCF		float			null
	,	UninsuredPrincipalCF	float			null
	,	InsuredInterestCF		float			null
	,	UninsuredInterestCF		float			null
	)
	--
	;
	--

	CREATE TABLE #lcr_EQB_Deposits
	(
		ID						int				not null	identity(1,1)	primary key		
	,	Product					varchar(40)		not null
	,	Relationship			varchar(40)		null
	,	Currency				varchar(3)		null
	,	Payment					varchar(12)		null
	,	InsuredPrincipalCF		float			null
	,	UninsuredPrincipalCF	float			null
	,	InsuredInterestCF		float			null
	,	UninsuredInterestCF		float			null
	)
	;
	--
	CREATE TABLE #lcr_EQB_Mortgage_Inflows
	(
		ID								int				not null	identity(1,1)	primary key		
	,	MBSPoolLocation					varchar(25)		null
	,	PaymentDateInNext30Days			bit				null
	,	InABCP							bit				null
	,	InWarehouse						bit				null
	,	ProductCategory_Name			varchar(25)		null
	,	OSFIType_IsInsured				bit				null
	,	PrincipalPayment_Balloon_CAD	float			null
	,	Total_InterestCashflow_CAD		float			null
	,	MBSInterestPayment				float			null
	,	PrincipalPayment_Scheduled		float			null
	)
	;
	--

	CREATE TABLE #lcr_EQB_Securitization_Cashflows
	(
		ID						int				not null	identity(1,1)	primary key	
	,	SecuritizationFlowType_Name					varchar(10)		null
	,	TransferDate			date			null
	,	Amount					float			null
	)
	;

	CREATE TABLE #lcr_EQB_Securitization_Loan_Maturities
	(
		ID						int				not null	identity(1,1)	primary key	
	,	MonthEnd				bit				not null
	,	Issuer					varchar(10)		null
	,	MBSPoolLocation			varchar(5)		null
	,	MaturityDate			date			null
	,	BalloonPrincipal		float			null
	)

	CREATE TABLE #lcr_Concentra_Derivative_Cashflow
	(
		ID						int				not null	identity(1,1)	primary key	
	,	Maturity				date			null
	,	Tran#					varchar(5)		null
	,	Identifier				varchar(20)		not null
	,	Face					float			null
	,	IssueDate				date			null
	,	Type					varchar(7)		null
	,	Cash					float			null
	,	LineNumber				varchar(9)		null
	,	Trans					int				null
	,	[Par/Receive]			varchar(1)		null
	,	Price					float			null
	,	Day						int				null
	)
	;

	CREATE TABLE #lcr_Concentra_Mgt_Commitment
	(
		Loan_Category			varchar(11)		not null
	,	TotalCommittedAmount	float		null
	)
	;

	CREATE TABLE #lcr_Concentra_Mgt_Inflow
	(
		ID								int				not null	identity(1,1)	primary key		
	,	MBSPoolLocation					varchar(30)		null
	,	PaymentDateInNext30Days			bit				null
	,	ProductCategoryname				varchar(25)		null
	,	ProductSubcategoryname			varchar(35)		null
	,	OSFIType_IsInsured				bit				null
	,	PrincipalPayment_Balloon_CAD	float			null
	,	Total_InterestCashflow_CAD		float			null
	,	MBSInterestPayment				float			null
	,	PrincipalPayment_Scheduled		float			null
	)
	;

	CREATE TABLE #lcr_EQB_LargestNetCollateralFlow 
	(
		ID				int			not null	identity(1,1)	primary key		
	--					
	,	[Value]			float		not null	
	--	
	)	
	--
	;
	--

	CREATE TABLE #lcr_EQB_UndisbursedCommitments	
	(
		ID						int		not null	identity(1,1)	primary key		
	--
	,	AllOtherCommitments		float	not null	
	,	LoanCategory			varchar(20)	not null
	--	
	)	
	--
	;

	CREATE TABLE #lcr_Check_NULL_EQB
	(
		ID							int		not null	identity(1,1)	primary key		
	--
	,	LCR_EQBLineItem_Number		int		not null	unique		
	,	[Value]						float	null				
	--	
	)	
	--
	;

	CREATE TABLE #lcr_Check_NULL_Concentra
	(
		ID							int		not null	identity(1,1)	primary key		
	--
	,	LCR_EQBLineItem_Number		int		not null	unique		
	,	[Value]						float	null				
	--	
	)	
	--
	;
	
	IF @DEBUG = 1 BEGIN PRINT dbo.fcn_DebugInfo( 'BEGIN ' + object_schema_name( @@PROCID ) + '.' + object_name( @@PROCID ) ) END ; 
		
	--
	--
	
	IF @MonthEnd IS NULL 
	BEGIN 
		IF @DEBUG = 1 PRINT dbo.fcn_DebugInfo( 'Null @MonthEnd parameter set to 0.' ) ;

		SET @MonthEnd = 0; 
	END		

	IF @EffectiveDate IS NULL 
	BEGIN 
		IF @MonthEnd = 0 
		BEGIN
			IF @DEBUG = 1 PRINT dbo.fcn_DebugInfo( 'Null @EffectiveDate parameter set to previous business date.' ) ;
			
			SET @EffectiveDate = marketinfo.fcn_BusinessDayOffset 
									(
										convert(date,@CurrentTimestamp)   --  InputDate 
									,	-1								  --  OffsetDays	
									,	@BusinessDayCalendar_Name		  --  BusinessDayCalendar_Name	
									)	
			--	
			;	
		END		
		ELSE BEGIN	
			IF @DEBUG = 1 PRINT dbo.fcn_DebugInfo( 'Null @EffectiveDate parameter set to latest available month-end date.' ) ;
			
			SET @EffectiveDate = dateadd(	day
										,	-day(dateadd(day,-1,convert(date,getdate())))
										,	dateadd(day,-1,convert(date,getdate()))
										) 
			--	
			;	
		END		
	END			
	
	--
	--

	--IF @MonthEnd = 1 
	--BEGIN 
	--	SET @YearNumber = YEAR(@EffectiveDate) ; 
	--	SET @MonthNumber = MONTH(@EffectiveDate) ; 
	
	--	IF MONTH(dateadd(day,1,@EffectiveDate)) = @MonthNumber	
	--	BEGIN 
	--		IF @DEBUG = 1 PRINT dbo.fcn_DebugInfo( '@EffectiveDate adjusted to end-of-month date.' ) ;
			
	--		SET @EffectiveDate = dateadd(day,-1, 
	--								dateadd(month,1,
	--									dateadd(day,1-day(@EffectiveDate),@EffectiveDate)
	--								 )
	--							  )
	--		--
	--		;	
	--	END		
	--END		

	--SET @MonthEnd = CASE WHEN @EffectiveDate = EOMONTH(@EffectiveDate) THEN 1			--	2025-01-02	Commented out
	--					ELSE 0 END;
	
	--
	--

	IF @DEBUG = 1 PRINT dbo.fcn_DebugInfo( '@EffectiveDate = ' + convert(varchar(10),@EffectiveDate) ) ; 
	IF @DEBUG = 1 PRINT dbo.fcn_DebugInfo( '@MonthEnd = ' + CASE @MonthEnd WHEN 1 THEN 'Y' ELSE 'N' END ) ; 

	--
	--

		--
		--	
		--	
		--	1.	GATHER INPUT DATA
		--	
		--
		--
		
	IF @DEBUG = 1 PRINT dbo.fcn_DebugInfo( '1 - GATHER INPUT DATA' ) ; 
		--
		--	Deposit Notes 	
		--
			
	IF @DEBUG = 1 PRINT dbo.fcn_DebugInfo( 'Gather maturing Deposit Notes.' ) ; 

		INSERT INTO #lcr_EQB_DepositNoteMaturities 		
		(
			DepositNoteID
		,	EffectiveDate	
		,	IssueDate	
		,	Name
		,	MaturityDate
		,	Currency
		,	FaceValue
		,	Price
		,	MonthEnd
		,	PaymentIn30Days
		,	PrincipalPaymentIn30Days
		,	InterestPaymentIn30Days
		)	
			
			SELECT	X.ID AS DepositNoteID
			,		CONVERT(smalldatetime, @EffectiveDate) AS EffectiveDate
			,       CONVERT(smalldatetime, X.IssueDate) AS IssueDate
			,		Name
			--,		CONVERT(smalldatetime, X.MaturityDate) as MaturityDate
			,		X.MaturityDate
			,		X.Currency_ThreeLetterAbbreviation as Currency
			,		X.FaceValue
			,		X.Price
			,		@MonthEnd as MonthEnd
			
			,		CASE WHEN MIN(Y.CashflowDate) <= dateadd(day, 30, @EffectiveDate)
						 THEN 1
						 ELSE 0
					END					PaymentIn30Days
			,		SUM(CASE WHEN Y.CashflowDate <= dateadd(day, 30, @EffectiveDate)
							 THEN Y.PrincipalRepayment_Ratio * X.FaceValue
							 ELSE 0
						END)			PrincipalPaymentIn30Days
			,		SUM(CASE WHEN Y.CashflowDate <= dateadd(day, 30, @EffectiveDate)
							 THEN Y.InterestPeriodRate_Effective * X.FaceValue
							 ELSE 0
						END)			InterestPaymentIn30Days
			
			--FROM TA.miscLiability.vw_DepositNote	X
			FROM	(SELECT CASE WHEN X.ID = 19
						AND		X.Name = 'Covered Bond - May 2022'
						AND		CONVERT(smalldatetime, X.MaturityDate) = '2025-05-27'
						AND		CONVERT(smalldatetime, X.IssueDate) = '2022-05-18'
						THEN	'2025-05-23'
						ELSE	CONVERT(smalldatetime, X.MaturityDate) END	MaturityDate		-- 2025-04-24 change MaturityDate for one Covered Bond	-- can be deleted after 2025-05-27
						,		X.Currency_ThreeLetterAbbreviation
						,		X.FaceValue
						,		X.Price
						,		X.ID
						,		X.IssueDate
						,		X.Name
						FROM TA.miscLiability.vw_DepositNote X)	X
			
			OUTER APPLY	miscLiability.fcn_DepositNote_Cashflow	(	X.ID		--	@DepositNoteID
																,	@EffectiveDate	--	@EffectiveTimestamp
																,	null		--	@OverrideCurveTimestamp
																,	null		--	@ParallelYieldShock
																)		
																	Y
			
			WHERE	X.IssueDate <= @EffectiveDate
			AND		X.MaturityDate > @EffectiveDate
			AND		Y.CashflowDate > @EffectiveDate
			
			GROUP BY	CONVERT(smalldatetime, X.IssueDate)
			,			Name
			,			CONVERT(smalldatetime, X.MaturityDate) 
			,			X.Currency_ThreeLetterAbbreviation 
			,			X.FaceValue
			,			X.Price
			,			X.ID
			
			ORDER BY	CONVERT(smalldatetime, X.MaturityDate)
						
						;		
			
		SET @RowCount = @@ROWCOUNT 
		IF @DEBUG = 1 BEGIN PRINT dbo.fcn_DebugInfo( ' rows: ' + convert(varchar(20),@RowCount) ) END ; 

	--
	--

		--
		--	Liquidity Portfolio		
		--
			
	IF @DEBUG = 1 PRINT dbo.fcn_DebugInfo( 'Pull Liquidity Portfolio details.' ) ; 

	BEGIN TRY	

		INSERT INTO #lcr_EQB_LiquidityPortfolio	
		(
			Category				
		,	Subcategory				
		,	Instrument_Issuer		
		,	LineItem				
		--
		,	CouponRate				
		,	MinSettlementDate		
		,	MaturityDate			
		,	FaceAmount				
		,	RemainingPrincipal		
		,	MarketValue				
		,	BookCost				
		,	PoolFactor				
		,	PoolNumber_Numeric		
		,	CUSIP					
		,	IsRedeemable			
		,	RedeemableDate			

		,	BondType_ShortName		
		--
		--
		,	IsFinancial				
		,	Rating_SP				
		,	RatingDate				
		,	AccruedInterest	
		,	MktValPlusAccrued
		,	IsPRA
		--				
		)	

			SELECT	
				CASE WHEN X.Category = 'MBS Repo' 
					 THEN 'Repo' 
					 ELSE X.Category 
				END as Category		
			--	
			,	CASE WHEN X.Category = 'MBS Repo' 
					 THEN 'MBS' 
					 ELSE X.Subcategory 
				END	as Subcategory	
			--	
			,	CASE WHEN X.Category = 'MBS Repo' 
						OR   ( X.Category = 'CASH' AND X.LineItem LIKE '%Clearing' ) 			
									OR   ( X.Category = 'CASH' AND X.LineItem LIKE '%Bennington%' ) 
												OR   ( X.Category = 'CASH' AND X.LineItem LIKE '%Miscellaneous%')
												OR   ( X.Category = 'CASH' AND X.LineItem LIKE '%Scotiabank Cash%')
												OR   ( X.Category = 'CASH' AND X.LineItem LIKE '%Special%Interest%')
												OR   ( X.Category = 'CASH' AND X.LineItem LIKE '%TD%Trust%')
												OR   ( X.Category = 'CASH' AND X.LineItem LIKE '%USD%')

					 THEN 'XX'

					 WHEN X.Category IN ('Cash','Market Investment', 'MBS') 
								 THEN X.Issuer_LegalEntity_ShortName

 

								 ELSE Null 
				END	AS Instrument_Issuer	
			--
			,	X.LineItem	
			--
			,	X.CouponRate	
			,	convert(smalldatetime,X.MinSettlementDate   )  as MinSettlementDate	
			,	convert(smalldatetime,X.MaturityDate	    )  as MaturityDate 
			,	X.FaceAmount 
			,	X.RemainingPrincipal 
			,	CASE WHEN X.Subcategory NOT IN ( 'Cashable Term' , 'Non-Cashable Term' ) 
					 THEN X.MarketValue - coalesce(X.AccruedInterest,0.00)	
					 ELSE X.MarketValue		
				END	AS MarketValue		 
			,	X.BookCost 
			,	X.PoolFactor 
			,	X.PoolNumber_Numeric 
			,	X.CUSIP			as	CUSIP	
			,	X.IsRedeemable	
			,   convert(smalldatetime, X.RedeemableDate ) as RedeemableDate 
			,	CASE WHEN X.Category = 'Market Investment' AND X.Subcategory = 'Reverse Repo'
					THEN coalesce(X.BondType_ShortName, X.Issuer_LegalEntity_ShortName)
					ELSE   X.BondType_ShortName	END BondType_ShortName
			,   X.isfinancial                                                                          -- add industry.financial/nonfinancial for bonds
			,   coalesce(X.Rating_SP, X.Rating_DBRS_SP, X.Rating_Moody_SP) As Rating_SP		-- use DBRS rating if no S&P rating
			,   convert(smalldatetime, X.CreditRating_EffectiveDate) As RatingDate
			,  coalesce(X.AccruedInterest,0.00) As AccruedInterest
			,	CASE WHEN X.Subcategory NOT IN ( 'Cashable Term' , 'Non-Cashable Term' ) 
					 THEN X.MarketValue	
					 ELSE X.MarketValue	+ coalesce(X.AccruedInterest,0.00)
				END	
			,   	CASE WHEN X.LineItem like '%PRA%'
						 THEN 1
						 ELSE 0
					END				IsPRA
			--	
			FROM	LiqPort.fcn_PositionSummary ( @EffectiveDate )  X	
			--
			WHERE X.Category != 'MBS Repo Contra' 
			--	
			ORDER BY X.Category	ASC		
			,                 X.Subcategory	ASC
			,	  X.LineItem	ASC 
			;
		
		SET @RowCount = @@ROWCOUNT 
		IF @DEBUG = 1 BEGIN PRINT dbo.fcn_DebugInfo( ' rows: ' + convert(varchar(20),@RowCount) ) END ; 

	END TRY		
	BEGIN CATCH		
		SET @ErrorMessage = 'An error was encountered while attempting to gather Liquidity Portfolio records.' 
		GOTO ERROR 
	END CATCH	

	--
	--
	--	Liquidity Portfolio	Concentra	
		--
			
	IF @DEBUG = 1 PRINT dbo.fcn_DebugInfo( 'Pull Liquidity Portfolio Concentra details.' ) ; 

	BEGIN TRY	

		INSERT INTO #lcr_Concentra_LiquidityPortfolio	
		(
			Category					
		,	Subcategory										
		--,	Instrument_Issuer
		,	Issuer_LegalEntity_ShortName
		--								
		,	PoolNumber_Numeric			
		,	BondType_ShortName			
		--								
		,	MaturityDate				
		,	FaceAmount					
		,	RemainingPrincipal			
		,	MarketValue		
		,	BookCost
		--
		,	Rating_SP		--	2020-07-03
		--
		,	CollateralType		--	2022-04-08
		,	LineItem
		,	MinSettlementDate
		--				
		)	
		SELECT	X.Category					
			,		X.Subcategory						
			,		CASE WHEN X.Category = 'MBS' AND X.Issuer_LegalEntity_ShortName IN ('Concentra', 'CONFIN')
						THEN X.Issuer_LegalEntity_ShortName
						WHEN X.Category = 'Pledge Contra' AND X.CollateralType = 'MBS' 
						AND X.Issuer_LegalEntity_ShortName IN ('Concentra', 'CONFIN')
						THEN X.Issuer_LegalEntity_ShortName
						ELSE NULL END Issuer_LegalEntity_ShortName
			--IN ('MBS', 'Pledge Contra')
			--			THEN CASE WHEN X.Issuer_LegalEntity_ShortName IN ('Concentra', 'CONFIN')
			--					THEN X.Issuer_LegalEntity_ShortName END
			--		END
			--X.Issuer_LegalEntity_ShortName
			
			--									
			,		X.PoolNumber_Numeric			
			,		X.BondType_ShortName			
			--									
			,		X.MaturityDate				
			,		X.OriginalFaceAmount					
			,		X.RemainingPrincipal
			,		X.MarketValue_Dirty
			--,		coalesce(X.MarketValue_Dirty, X.MarketValue_Clean)		
			,		X.BookValue	
			--
			,		coalesce(X.Rating, '')		--	2020-07-03	adding credit rating	--	2022-09-28	Adding Moody's rating
			--
			,		CASE WHEN X.Category IN ('MBS', 'Pledge Contra', '1CRPBD') THEN X.CollateralType END CollateralType
			--X.CollateralType									
			,		X.LineItem
			,		X.MinSettlementDate
			--		
			FROM	Liqport.PositionSummary_Cache_Concentra	X	
			--
				--
				--	2019-02-12	
				--	
			WHERE	X.PositionDate = @EffectiveDate
				AND coalesce(X.Subcategory,'xx') != 'Cashable Deposit'		
				--OR	X.PositionDate <= dateadd(day,30,@EffectiveDate)	
				--
				--	// 2019-02-12	
				--	
			--	
			;
					
		
		SET @RowCount = @@ROWCOUNT 
		IF @DEBUG = 1 BEGIN PRINT dbo.fcn_DebugInfo( ' rows: ' + convert(varchar(20),@RowCount) ) END ; 

	END TRY		
	BEGIN CATCH		
		SET @ErrorMessage = 'An error was encountered while attempting to gather Liquidity Portfolio Concentra records.' 
		GOTO ERROR 
	END CATCH	

	--

		--
		--	MBS Repos		
		--
	
	--IF @DEBUG = 1 PRINT dbo.fcn_DebugInfo( 'Pull MBS Repo positions.' ) ; 

	--BEGIN TRY	

	--	EXEC @ProcedureReturnValue = liquidity_exec.usp_Calculate_MBSRepo_Valuation 
	--				@ReportDate				=	@EffectiveDate 
	--			,	@IncludeYieldShocks		=	0 
	--			,	@Mode					=	'TEMP'	
	--			,	@DEBUG					=	0	
	--	--
	--	;	

	--	--
	--	--

	--		IF @ProcedureReturnValue = -1 
	--		BEGIN 
	--			SET @ErrorMessage = 'An error occurred during subroutine.' 
	--			GOTO ERROR 
	--		END 
		
	--	--
	--	--
			
	--	SELECT @RowCount = COUNT(*) FROM #usp_Calculate_MBSRepo_Valuation_Output X	
	--	--
	--	;	
	--	IF @DEBUG = 1 BEGIN PRINT dbo.fcn_DebugInfo( ' rows: ' + convert(varchar(20),@RowCount) ) END ; 

	--END TRY 
	--BEGIN CATCH		
	--	SET @ErrorMessage = 'An error was encountered while attempting to gather MBS Repo positions.' 
	--	GOTO ERROR 
	--END CATCH	
	--
	--

	IF @DEBUG = 1 PRINT dbo.fcn_DebugInfo( 'Extract Concentra Deposits value' ) ; 

	BEGIN TRY

		INSERT INTO #lcr_Concentra_Deposits  
		(
			SourceTable				
		,	Category				
		,	Currency				
		,	DepositType				
		,	Payment					
		,	InsuredPrincipalCF		
		,	UninsuredPrincipalCF	
		,	InsuredInterestCF		
		,	UninsuredInterestCF		
		)
		SELECT	       
			 X.SourceTable
		,	coalesce(X.Category + C.OriginalTermFlag, X.Category)	Category
		,	X.Currency
		,	X.DepositType
		,	CASE WHEN X.Category = 'Demand'
				 THEN '<= 30 Days'
				 WHEN X.Category LIKE '%Notice%Given%'
				 THEN '<= 30 Days'
				 ELSE C.Payment
			END				Payment
		,	coalesce( C.InsuredPrincipalCF	  , X.InsuredBalance )		InsuredPrincipalCF
		,	coalesce( C.UninsuredPrincipalCF  , X.UninsuredBalance )	UninsuredPrincipalCF
		,	coalesce( C.InsuredInterestCF	  , X.InsuredInterest )		InsuredInterestCF
		,	coalesce( C.UninsuredInterestCF	  , X.UninsuredInterest )	UninsuredInterestCF
--
	FROM	(
				SELECT	CASE WHEN X.Referral = 'Credit Union'
							 THEN X.SourceTable + ' - Credit Union'
							 ELSE SourceTable
						END		SourceTable
				,		CASE WHEN X.ProductType like '%Notice Given%'
							 THEN 'Notice Given'   
							 WHEN X.AccountNumber = '830260092762'
							 THEN 'Notice - Atlantic'
							 WHEN X.ProductType like '%Notice%'
							 THEN 'Notice Deposit'
							 WHEN X.Red_NonRed is null
							 THEN 'Demand'
							 ELSE X.Red_NonRed
						END	Category
				,		CASE WHEN X.ProductType like '%US%' THEN 'USD'
							 ELSE 'CAD'
						END		Currency
				,		CASE WHEN X.SourceTable like '%Commercial%' OR (X.SourceTable like '%CreditUnion%' AND X.Major IS NOT NULL)  --2025-07-14
							 THEN	CASE WHEN FI.FI_Name is not null
										 THEN 'OLE'
										 WHEN X.Balance > 1500000
										 THEN 'WS'
										 ELSE 'SB'
									END	
						END						[DepositType]
				,		SUM(I.InsuredBalance)		InsuredBalance
				,		SUM(I.UninsuredBalance)		UninsuredBalance
				,		SUM(CASE WHEN X.Balance > 100000
								   THEN 0.00
								   ELSE X.AccruedInterest + X.Comp_Int_to_Date
								END	)			InsuredInterest
				,		SUM(CASE WHEN X.Balance <= 100000			--	2025-05-05	Changed from < to <= to cover case when balance = 100000
										THEN 0.00 
										ELSE X.AccruedInterest + X.Comp_Int_to_Date
								END	)		UninsuredInterest
				--
				FROM	(
							SELECT MAX(Xs.AsofDate) MAXAsofDate
							FROM Concentra.TBSM.vw_Deposits_Daily Xs
							WHERE Xs.AsofDate <= @EffectiveDate
						)	
							Xs
				LEFT JOIN Concentra.TBSM.vw_Deposits_Daily  X on Xs.MAXAsofDate = X.AsofDate
				--
				LEFT JOIN Concentra.TBSM.Deposit_Commercial_Daily CM	ON Xs.MAXAsofDate = CM.[As of] 
																		AND (  (X.SourceTable = 'Commercial_Client' AND CM.Product NOT LIKE 'CU%') OR (X.SourceTable = 'CreditUnion_Deposit' AND CM.Product LIKE 'CU%')  )	 --2025-07-14
																		AND X.AccountNumber = CM.[Account Number]
				LEFT JOIN Concentra.TBSM.Deposit_Commercial_FinancialInstitution FI	ON CM.[Lastname, Firstname] = FI.FI_Name
				--
				LEFT JOIN Concentra.TBSM.Deposit_Credit_Union_Daily CU	ON Xs.MAXAsofDate = X.FileDate 
																		 AND CU.Account_No = X.AccountNumber 
																		  AND X.SourceTable = 'CreditUnion_Deposit'
				OUTER APPLY	(
								SELECT	CASE WHEN X.Balance < 0	 THEN 0.00
												WHEN X.Balance >= 100000 THEN 100000
												ELSE X.Balance
										END		InsuredBalance
										, CASE WHEN X.Balance < 0	 THEN 0.00
												WHEN X.Balance >= 100000 THEN X.Balance - 100000
												ELSE 0.00
										END		UninsuredBalance
							)	
								I
				--
				GROUP BY SourceTable
				,		CASE WHEN X.ProductType like '%Notice Given%'
							 THEN 'Notice Given'   
							 WHEN X.AccountNumber = '830260092762'
							 THEN 'Notice - Atlantic'
							 WHEN X.ProductType like '%Notice%'
							 THEN 'Notice Deposit'
							 WHEN X.Red_NonRed is null
							 THEN 'Demand'
							 ELSE X.Red_NonRed
						END
				,		CASE WHEN X.ProductType like '%US%' THEN 'USD'
							 ELSE 'CAD'
						END		
				,		CASE WHEN X.SourceTable like '%Commercial%' OR (X.SourceTable like '%CreditUnion%' AND X.Major IS NOT NULL)		-- 2025-07-14
							 THEN	CASE WHEN FI.FI_Name is not null
										 THEN 'OLE'
										 WHEN X.Balance > 1500000
										 THEN 'WS'
										 ELSE 'SB'
									END	
						END	
				,		CASE WHEN X.Referral = 'Credit Union'
							 THEN X.SourceTable + ' - Credit Union'
							 ELSE SourceTable
						END	
				--
			)
				X
	--
			LEFT  JOIN	(
					SELECT	CASE WHEN X.GICSourceTable = 'Retail_Deposit' AND X.Referral  = 'Credit Union'
								 THEN 'Retail_Deposit - Credit Union'
								 ELSE GICSourceTable
							END			GICSourceTable
					,		P.Payment
					,		CASE WHEN X.GICSourceTable = 'CreditUnion_Deposit'
								 AND  X.GICType_Name = 'Non-Redeemable'
								 AND  X.OriginalTerm_Rounded_Months = 0
								 THEN '_OrgTerm<=30Day'
								 ELSE ''
							END			OriginalTermFlag
					--,		DATEDIFF(DAY,@RunDate , PaymentDate)						[Period]
					,		SUM(PrincipalCashflow)										PrincipalCF
					,		SUM(interestCashflow)										InterestCashflow
					,		SUM(PrincipalCashflow * EstimatedUninsuredPercentage)		UninsuredPrincipalCF
					,		SUM(PrincipalCashflow * (1-EstimatedUninsuredPercentage))	InsuredPrincipalCF
					,		SUM(interestCashflow * EstimatedUninsuredPercentage)		UninsuredInterestCF
					,		SUM(interestCashflow * (1-EstimatedUninsuredPercentage))	InsuredInterestCF
					--,		OriginalTerm_Rounded_Months
					,		CASE WHEN GICType_Name LIKE '%Notice%Given%'
									 THEN 'Notice Given'
									 WHEN GICType_Name = 'Notice - Atlantic'
									 THEN 'Notice - Atlantic'
									 WHEN GICType_Name like '%Notice%'
									 THEN 'Notice Deposit'
									 ELSE GICType_Name
								END		GICType_Name
					,		Currency_ThreeLetterAbbreviation
					,		CASE WHEN DepositType in ('WS - LCR; SB - NCCF')	THEN 'WS'
								 ELSE DepositType
							END															DepositType
					FROM	(
								SELECT	MAX(Xs.EffectiveDate) MAXAsofDate
								FROM	Concentra.deposit.GICcashflow Xs
								WHERE	Xs.EffectiveDate <= @EffectiveDate
								AND		GICCashflowVersionConfigurationID = 2
							)	
								Xs
					LEFT JOIN  Concentra.deposit.GICcashflow  X  ON X.EffectiveDate = Xs.MAXAsofDate
					--
					OUTER APPLY	(
									SELECT	CASE WHEN X.PaymentDate <= dateadd(day, 30, @EffectiveDate)		-- 2025-07-16 change from X.EffectiveDate to @EffectiveDate
												 THEN '<= 30 Days'
												 ELSE '> 30 Days'
											END				Payment
								)
									P
					--
					WHERE GICCashflowVersionConfigurationID = 2 
					AND X.PaymentDate > @EffectiveDate		-- 2025-07-16
					--
					GROUP BY	CASE WHEN X.GICSourceTable = 'Retail_Deposit' AND X.Referral = 'Credit Union'
									 THEN 'Retail_Deposit - Credit Union'
									 ELSE GICSourceTable
								END	
					,			P.Payment
					,			CASE WHEN X.GICSourceTable = 'CreditUnion_Deposit'
									 AND  X.GICType_Name = 'Non-Redeemable'
									 AND  X.OriginalTerm_Rounded_Months = 0
									 THEN '_OrgTerm<=30Day'
									 ELSE ''
								END	
					--,			OriginalTerm_Rounded_Months
					,			CASE WHEN GICType_Name LIKE '%Notice%Given%'
									 THEN 'Notice Given'
									 WHEN GICType_Name = 'Notice - Atlantic'
									 THEN 'Notice - Atlantic'
									 WHEN GICType_Name like '%Notice%'
									 THEN 'Notice Deposit'
									 ELSE GICType_Name
								END
					,			Currency_ThreeLetterAbbreviation
					,			CASE WHEN DepositType in ('WS - LCR; SB - NCCF')	THEN 'WS'
									 ELSE DepositType
								END		
				)
					C	ON	X.SourceTable = C.GICSourceTable
						AND X.Category = C.GICType_Name
						AND X.Currency = C.Currency_ThreeLetterAbbreviation
						AND (
								X.DepositType = C.DepositType
							OR	( X.DepositType IS NULL AND C.DepositType IS NULL )
							)
	--
	;
		
	END TRY		
	BEGIN CATCH		
		SET @ErrorMessage = 'An error was encountered while attempting to extract Concentra Deposits.' 
		GOTO ERROR 
	END CATCH

	--	Extract EQB Deposit

	IF @DEBUG = 1 PRINT dbo.fcn_DebugInfo( 'Extract EQB Deposits value' ) ; 

	BEGIN TRY
		IF OBJECT_ID('tempdb..#usp_RelationshipBalances_Output') IS NOT NULL DROP TABLE #usp_RelationshipBalances_Output
		CREATE TABLE #usp_RelationshipBalances_Output
		(
			EffectiveDate					date			not null	
		--									
		,	Relationship					varchar(100)	not null	
		,	SmallBusinessType				varchar(50)		null					--	2025-08-18
		--									
		,	TotalCustomers					int				not null	
		--
		,	SavingsBalance_Insured						float	not null
		,	SavingsBalance_Uninsured					float	not null
		,	UpcomingMaturities_Insured					float	not null
		,	UpcomingMaturities_Uninsured				float	not null
		,	PromoBalance_Insured						float	not null
		,	PromoBalance_Uninsured						float	not null
		,	Registered_PromoBalance_Insured				float	not null			-- 2025-03-31
		,	Registered_PromoBalance_Uninsured			float	not null			-- 2025-03-31
		,	SavingBalanceUSD_convertedCAD_Insured		float	not null
		,	SavingBalanceUSD_convertedCAD_Uninsured		float	not null
		,	GICPrincipal_Over30_Insured					float	not null
		,	GICPrincipal_Over30_Uninsured				float	not null
		,	FHSA_UpcomingMaturities_Insured				float	not null			--	2025-01-08
		,	FHSA_UpcomingMaturities_Uninsured			float	not null			--	2025-01-08
		,	FHSA_GICPrincipal_Over30_Insured			float	not null			--	2025-01-08
		,	FHSA_GICPrincipal_Over30_Uninsured			float	not null			--	2025-01-08
		,	DayNotice10_Insured							float	not null
		,	DayNotice10_Uninsured						float	not null
		,	DayNoticeGiven10_Insured					float	not null
		,	DayNoticeGiven10_Uninsured					float	not null
		,	DayNotice30_Insured							float	not null
		,	DayNotice30_Uninsured						float	not null
		,	DayNoticeGiven30_Insured					float	not null
		,	DayNoticeGiven30_Uninsured					float	not null
		--				
		,	UNIQUE	(  EffectiveDate , Relationship, SmallBusinessType) 	
		--	
		)	
		;
		--
		IF OBJECT_ID('tempdb..#usp_RelationshipBalances_CustomerLevel_Output') IS NOT NULL DROP TABLE #usp_RelationshipBalances_CustomerLevel_Output
		CREATE TABLE #usp_RelationshipBalances_CustomerLevel_Output
		(
			EffectiveDate					date			not null	
		--									
		,	CustomerNumber					int				not null
		--
		,	Relationship					varchar(100)	not null	
		,	SmallBusinessType				varchar(50)		null					--	2025-08-18
		--				
		,	SavingsBalance_Insured						float	not null
		,	SavingsBalance_Uninsured					float	not null
		,	UpcomingMaturities_Insured					float	not null
		,	UpcomingMaturities_Uninsured				float	not null
		,	PromoBalance_Insured						float	not null
		,	PromoBalance_Uninsured						float	not null
		,	Registered_PromoBalance_Insured				float	not null			-- 2025-03-31
		,	Registered_PromoBalance_Uninsured			float	not null			-- 2025-03-31
		,	SavingBalanceUSD_convertedCAD_Insured		float	not null
		,	SavingBalanceUSD_convertedCAD_Uninsured		float	not null
		,	GICPrincipal_Over30_Insured					float	not null
		,	GICPrincipal_Over30_Uninsured				float	not null
		,	DayNotice10_Insured							float	not null
		,	FHSA_UpcomingMaturities_Insured				float	not null			--	2025-01-08
		,	FHSA_UpcomingMaturities_Uninsured			float	not null			--	2025-01-08
		,	FHSA_GICPrincipal_Over30_Insured			float	not null			--	2025-01-08
		,	FHSA_GICPrincipal_Over30_Uninsured			float	not null			--	2025-01-08
		,	DayNotice10_Uninsured						float	not null
		,	DayNoticeGiven10_Insured					float	not null
		,	DayNoticeGiven10_Uninsured					float	not null
		,	DayNotice30_Insured							float	not null
		,	DayNotice30_Uninsured						float	not null
		,	DayNoticeGiven30_Insured					float	not null
		,	DayNoticeGiven30_Uninsured					float	not null
		--				
		,	UNIQUE	(  EffectiveDate , CustomerNumber , Relationship, SmallBusinessType) 	
		--	
		)	
		;

		EXEC	DigitalBanking.report_exec.usp_RelationshipBalances_LCR 
					@Report_EndDate	=	@EffectiveDate
				--
				,	@Mode			=	'TEMP'
				--
				,	@DEBUG			=	1	
		;

		INSERT INTO #lcr_EQB_Deposits
		(	
			Product				
		,	Relationship		
		,	Currency			
		,	Payment				
		,	InsuredPrincipalCF	
		,	UninsuredPrincipalCF
		,	InsuredInterestCF	
		,	UninsuredInterestCF	
		)
		SELECT	CASE WHEN X.Product LIKE 'Brokered HISA%'
					 THEN 'Brokered HISA'
					 ELSE X.Product
				END                                   Product
		,		CASE WHEN X.Product LIKE 'Brokered HISA%'
					 THEN REPLACE(X.Product,'Brokered HISA - ','')
					 ELSE coalesce(X.Relationship,C.Relationship)
				END                                   Relationship
		,		X.Currency
		,		CASE WHEN X.Product IN ('Brokered HISA - Relationship','Brokered HISA - Non-Relationship','Digital Savings' , 'Digital Savings - Promo' , 'Digital Savings - Registered - Promo', 'Digital Savings - USD' , 'NSA - 10 Day' , 'NSA - 10 Day (Notice Given)' , 'NSA - 30 Day (Notice Given)' , 'IPC_Investment')
					 THEN '<= 30 Days'
					 WHEN X.Product IN ('NSA - 30 Day')
					 THEN '> 30 Days'
					 ELSE C.Maturity
				END                                   Payment
		,		coalesce( C.TotalPrincipal_Insured   , X.Principal_Insured )				InsuredPrincipalCF
		,		coalesce( C.TotalPrincipal_Uninsured , X.Principal_Uninsured )				UninsuredPrincipalCF
		,		coalesce( C.TotalInterest_Insured	 , X.Interest_Insured )					InsuredInterestCF
		,		coalesce( C.TotalInterest_Uninsured  , X.Interest_Uninsured )				UninsuredInterestCF
		--
		FROM   (
					SELECT	CONVERT(smalldatetime, X.EffectiveDate) EffectiveDate
					,		X.Product + CASE WHEN X.SimplifiedOwnerType = 'FHSA'
											 THEN ' - FHSA'
											 ELSE ''
										END				Product			--	2025-01-07
					,		CASE WHEN X.Product LIKE 'Brokered HISA%'
								 THEN REPLACE(X.Product,'Brokered HISA - ','')
							END                     Relationship
					,		X.Currency_ThreeLetterAbbreviation   Currency
					--		
					,		CASE WHEN X.Product = 'Brokered HISA - Relationship' and X.Currency_ThreeLetterAbbreviation = 'CAD'
								 THEN SUM(X.Principal_insured_CAD) - Y.Insured 
								 ELSE SUM(X.Principal_insured_CAD) 
							END                                                 Principal_Insured
					,		CASE WHEN X.Product = 'Brokered HISA - Relationship' and X.Currency_ThreeLetterAbbreviation = 'CAD'
								 THEN SUM(X.Principal_Uninsured_CAD) - Y.Uninsured 
								 ELSE SUM(X.Principal_Uninsured_CAD) 
							END                                                 Principal_Uninsured
					--		
					,		 SUM(X.Interest_Insured_CAD)               Interest_Insured
					,		 SUM(X.Interest_Uninsured_CAD)             Interest_Uninsured

					,		 1 AS MonthEnd

					FROM		liquidity.vw_DepositBalanceSummary_ResultCache  X 
					LEFT  JOIN  (
									SELECT	Ys.TradeDate as TradeDate
									--
									,		SUM(CASE WHEN Ys.TotalValue > 100000.0000
													 THEN 100000.0000
													 ELSE Ys.TotalValue
												END)                     as	Insured                             
									,       SUM(CASE WHEN Ys.TotalValue > 100000.0000
													 THEN Ys.TotalValue - 100000.0000
													 ELSE 0.0000 
												END)                     as	Uninsured         
									FROM   (
												select TradeDate, sum(totalinflows + Totaloutflows) over (order by tradedate)as Totalvalue 
												from BrokeredHISA.core.vw_TransactionSummary_Cache  
												where FundID=31
										   ) Ys 
									GROUP BY	Ys.tradedate
									--
								)  Y	ON	Y.tradedate = marketinfo.fcn_BusinessDayAdjustment ( X.EffectiveDate , 'MF'  , 'Toronto' )        
					--
					WHERE	X.EffectiveDate = @EffectiveDate 
					AND		X.MonthEnd = @MonthEnd
					AND		X.Product NOT IN ('Digital NSA 10 day' , 'Digital NSA 30 day' , 'Digital Savings')
					--
					GROUP BY X.EffectiveDate
					,        X.Product + CASE WHEN X.SimplifiedOwnerType = 'FHSA'
											 THEN ' - FHSA'
											 ELSE ''
										END	--	2025-01-07
					,		 X.Product 
					,        X.Currency_ThreeLetterAbbreviation
					,		 Y.Insured
					,		 Y.Uninsured
					--
					UNION ALL
					--
					SELECT	@EffectiveDate
					,		'IPC_Investment'
					--
					,		'Relationship'                                Relationship
					--
					,		'CAD'
					,		SUM(CASE WHEN Ys.TotalValue > 100000.0000
									 THEN 100000.0000
									 ELSE Ys.TotalValue
								END)                                               as          Insured                             
					,		SUM(CASE WHEN Ys.TotalValue > 100000.0000
									 THEN Ys.TotalValue - 100000.0000
									 ELSE 0.0000 
								END)                                               as          Uninsured         
					,		0
					,		0
					,		1
					FROM   (
								SELECT TradeDate, sum(totalinflows + Totaloutflows) over (order by tradedate)as Totalvalue 
								FROM BrokeredHISA.core.vw_TransactionSummary_Cache  where FundID=31
						   ) Ys 
					WHERE		YS.TradeDate = marketinfo.fcn_BusinessDayAdjustment ( @EffectiveDate , 'MF'  , 'Toronto' )           
					GROUP BY	Ys.tradedate
					--
					UNION ALL
					--
					SELECT	EffectiveDate
					,		P.ProductType
					,		L.Relationship 
					,		CASE WHEN P.ProductType LIKE '%USD%'
								 THEN 'USD'
								 ELSE 'CAD'
							END			Currency
					,		CASE WHEN P.ProductType = 'Digital GIC'
								 THEN SUM(L.UpcomingMaturities_Insured + L.GICPrincipal_Over30_Insured)
								 WHEN P.ProductType = 'Digital Savings'
								 THEN SUM(L.SavingsBalance_Insured)
								 WHEN P.ProductType = 'Digital Savings - Promo'
								 THEN SUM(L.PromoBalance_Insured)
								 WHEN P.ProductType = 'Digital Savings - USD'
								 THEN SUM(L.SavingBalanceUSD_convertedCAD_Insured)
								 WHEN P.ProductType = 'Digital Savings - Registered - Promo'		-- 2025-03-31
                                 THEN SUM(L.Registered_PromoBalance_Insured)
								 WHEN P.ProductType = 'NSA - 10 Day'
								 THEN SUM(L.DayNotice10_Insured)
								 WHEN P.ProductType = 'NSA - 10 Day (Notice Given)'
								 THEN SUM(L.DayNoticeGiven10_Insured)
								 WHEN P.ProductType = 'NSA - 30 Day'
								 THEN SUM(L.DayNotice30_Insured)
								 WHEN P.ProductType = 'NSA - 30 Day (Notice Given)'
								 THEN SUM(L.DayNoticeGiven30_Insured)
								 ELSE 0.00
							END			Principal_Insured
					,		CASE WHEN P.ProductType = 'Digital GIC'
								 THEN SUM(L.UpcomingMaturities_Uninsured + L.GICPrincipal_Over30_Uninsured)
								 WHEN P.ProductType = 'Digital Savings'
								 THEN SUM(L.SavingsBalance_Uninsured)
								 WHEN P.ProductType = 'Digital Savings - Promo'
								 THEN SUM(L.PromoBalance_Uninsured)
								 WHEN P.ProductType = 'Digital Savings - USD'
								 THEN SUM(L.SavingBalanceUSD_convertedCAD_Uninsured)
								 WHEN P.ProductType = 'Digital Savings - Registered - Promo'		-- 2025-03-31
                                 THEN SUM(L.Registered_PromoBalance_Uninsured)
								 WHEN P.ProductType = 'NSA - 10 Day'
								 THEN SUM(L.DayNotice10_Uninsured)
								 WHEN P.ProductType = 'NSA - 10 Day (Notice Given)'
								 THEN SUM(L.DayNoticeGiven10_Uninsured)
								 WHEN P.ProductType = 'NSA - 30 Day'
								 THEN SUM(L.DayNotice30_Uninsured)
								 WHEN P.ProductType = 'NSA - 30 Day (Notice Given)'
								 THEN SUM(L.DayNoticeGiven30_Uninsured)
								 ELSE 0.00
							END			Principal_Uninsured
					,		0
					,		0
					,		1
					FROM   #usp_RelationshipBalances_Output  L              
					INNER JOIN	(VALUES
												 /*('Digital GIC')
								 ,             */('Digital Savings')
								 ,             ('Digital Savings - Promo')
								 ,             ('Digital Savings - USD')
								 ,			   ('Digital Savings - Registered - Promo')				-- 2025-03-31
								 ,             ('NSA - 10 Day')
								 ,             ('NSA - 10 Day (Notice Given)')
								 ,             ('NSA - 30 Day')
								 ,             ('NSA - 30 Day (Notice Given)')
								 )
									P	(ProductType)	ON	1 = 1
					--
					GROUP BY	EffectiveDate
					,           P.ProductType
					,           L.Relationship 
					,           CASE WHEN P.ProductType LIKE '%USD%'
									 THEN 'USD'
									 ELSE 'CAD'
								END                                   
					--
					--
		)
					X
		--
		LEFT  JOIN	(
						SELECT	convert(smalldatetime,X.EffectiveDate ) as EffectiveDate 
						,       CASE WHEN X.GICProductChannel_Name = 'Deposit Services'
									 THEN 'Brokered GIC - '
									 ELSE 'Digital GIC - '
								END + X.GICType_Name
							+	CASE WHEN coalesce(X.IsFHSA,0) = 1
									 THEN ' - FHSA'				--	2025-01-07
									 ELSE ''					--	2025-01-07
								END					as	Product              
						,       X.Currency_ThreeLetterAbbreviation            as	Currency
						,       CASE WHEN (X.GICProductChannel_Name = 'Digital Banking' AND X.IsRelationship = 1) 
									 THEN 'NonTransactional / Relationship' 
									 WHEN X.GICProductChannel_Name = 'Digital Banking'
									 THEN 'NonTransactional / NonRelationship'
									 ELSE 'Non-Relationship' 
								END                AS Relationship     
						,       CASE WHEN DateDiff(day,X.EffectiveDate,P.PaymentDate) <= 30 THEN '<= 30 Days' ELSE '> 30 Days' END AS Maturity
						,       ROUND(SUM(X.TotalPrincipal_CAD - X.UninsuredPrincipal_Estimate_CAD),2)                         TotalPrincipal_Insured
						,       ROUND(SUM(X.UninsuredPrincipal_Estimate_CAD),2)                                                                                                                                 TotalPrincipal_Uninsured
						,       ROUND(SUM(X.TotalInterest_CAD * (1.0000 - coalesce(X.EstimatedUninsuredPercentage,0.00))),2)   TotalInterest_Insured
						,       ROUND(SUM(X.TotalInterest_CAD * coalesce(X.EstimatedUninsuredPercentage,0.00)),2)              TotalInterest_Uninsured
						,       ROUND(SUM(CASE WHEN X.TotalPrincipal_CAD > 0.000 
											   THEN X.CertificateCount
											   ELSE 0.000 
										  END),8)                                                                                                                   CertificateCount            
						--
						,       CASE WHEN SUM(X.TotalPrincipal_CAD) <= 0.0000 
									 THEN 0.0000 
									 ELSE SUM(X.WeightedAverageAnnualRate*X.TotalPrincipal)/SUM(X.TotalPrincipal) 
								END                                                                                                                                       WeightedAverageAnnualRate
						,       @MonthEnd As MonthEnd          
						--                          
						FROM	deposit.fcn_GICCashflow 
									(             
										@EffectiveDate			--  @EffectiveDate                                                                                 
									,   @MonthEnd           --  @MonthEnd                                                                                        
									,   0                   --  @UseCashableGICRedemptionAssumption   
									,   0                   -- @UseDigitalCancellationAssumption                             
									--  
									,   null                -- @MaximumCashflowDate    
									,   1                   --  @ApplyBusinessDayAdjustments    
									--
									)             
										X 
						OUTER APPLY	(
										SELECT	CASE WHEN X.GICProductChannel_Name = 'Deposit Services'		--	Using following business day for weekend brokered GIC deposits, but weekends are ok for Digital
													 THEN X.PaymentDate_Adjusted
													 ELSE X.PaymentDate
												END                                   PaymentDate
									)
										P
						LEFT JOIN	TA.TDBlookup.AgentNumber Y	ON X.AgentNumber = Y.Code
						--
						GROUP BY	X.EffectiveDate 
						,           CASE WHEN X.GICProductChannel_Name = 'Deposit Services'
										 THEN 'Brokered GIC - '
										 ELSE 'Digital GIC - '
									END + X.GICType_Name
								+	CASE WHEN coalesce(X.IsFHSA,0) = 1
										 THEN ' - FHSA'				--	2025-01-07
										 ELSE ''					--	2025-01-07
									END			
						,           X.Currency_ThreeLetterAbbreviation
						,           CASE WHEN DateDiff(day,X.EffectiveDate,P.PaymentDate) <= 30 THEN '<= 30 Days' ELSE '> 30 Days' END
						,           CASE WHEN (X.GICProductChannel_Name = 'Digital Banking' AND X.IsRelationship = 1) 
										 THEN 'NonTransactional / Relationship' 
										 WHEN X.GICProductChannel_Name = 'Digital Banking'
										 THEN 'NonTransactional / NonRelationship'
										 ELSE 'Non-Relationship' 
									END

					)
						C	ON	X.Product = C.Product
							AND X.Currency = C.Currency
		--
		;

	END TRY		
	BEGIN CATCH		
		SET @ErrorMessage = 'An error was encountered while attempting to extract EQB Deposits. ' 
		GOTO ERROR 
	END CATCH	

	--
	--	Extract Concentra Mortgage Inflows

	IF @DEBUG = 1 PRINT dbo.fcn_DebugInfo( 'Extract EQB Mortgage Inflows' ) ; 

	BEGIN TRY
		INSERT INTO #lcr_EQB_Mortgage_Inflows
		(
			MBSPoolLocation					
		,	PaymentDateInNext30Days			
		,	InABCP							
		,	InWarehouse						
		,	ProductCategory_Name			
		,	OSFIType_IsInsured				
		,	PrincipalPayment_Balloon_CAD	
		,	Total_InterestCashflow_CAD		
		,	MBSInterestPayment				
		,	PrincipalPayment_Scheduled		
		)
		SELECT
		--,	G.PoolNumber
			CASE WHEN Split.CategoryCode IS NOT NULL
					THEN Split.CategoryCode
					WHEN X.PoolNumber IS NOT NULL
					THEN 'MBS on Balance Sheet'
			END				MBSPoolLocation
		,	CASE WHEN datediff(day, @EffectiveDate, X.PaymentDate)	<= 30 AND X.PaymentDate > @EffectiveDate
					THEN 1
					ELSE 0
			END				PaymentDateInNext30Days
		--,	CASE WHEN X.ProductCategoryName = 'Loans' AND M.LoanTypeCode IN (33,34)
		--		 THEN 'Commercial Mortgage'
		--		 WHEN X.ProductCategoryName = 'Loans' 
		--		 THEN 'Commercial Loan'
		--	ELSE X.ProductCategoryName
		--	END			ProductCategoryName
		,	CASE WHEN X.LoanEncumbranceTypeCategory_ShortName = 'ABCP'
				THEN 1 ELSE 0 END InABCP
		,	CASE WHEN X.WarehouseFacility_ShortName IS NOT NULL
				THEN 1 ELSE 0 END InWarehouse
		,	X.ProductCategory_Name
		,	X.OSFIType_IsInsured
		,	SUM(PrincipalPayment_Balloon_CAD * coalesce(Split.AllocationPercentage, 1.0000))	PrincipalPayment_Balloon_CAD
		,	SUM(Total_InterestCashflow_CAD * coalesce(Split.AllocationPercentage, 1.0000))		Total_InterestCashflow_CAD
		,	SUM(MBSInterestPayment_Estimated * coalesce(Split.AllocationPercentage, 1.0000))	MBSInterestPayment	
		,	SUM(PrincipalPayment_Scheduled * coalesce(Split.AllocationPercentage, 1.0000))		PrincipalPayment_Scheduled 

		FROM		[loan].[fcn_PortfolioCashflow] 
									(	
										'LCR'			--	@VersionConfiguration_Note
									--
									,	@EffectiveDate	--  @EffectiveDate						
									,	@MonthEnd				--  @MonthEnd			
									--
									,	null			--	@MaximumCashflowDate	
									,	0				--	@ApplyBusinessDayAdjustments	
									--
									)	
										X
		LEFT JOIN loan.PortfolioCashflowAttributeGroup G ON G.ID= X.PortfolioCashflowAttributeGroupID
		LEFT JOIN  (	SELECT	EffectiveDate														
							,	PoolNumber_Numeric
							--,	MAX(Coupon)	Coupon					
							--,	MAX(Type)	Type
							,	Percentage_BS
							,	Percentage_CHT
							,	Percentage_Sold
							--,	MAX(coalesce(FaceAmount_Sold,0.0000))	Sold_pct
 
						FROM	TA.securitization.fcn_MBSAllocation ( null , @EffectiveDate )
						--WHERE	EffectiveDate = @RunDate
						--GROUP BY	EffectiveDate, PoolNumber_Numeric
					)	Z	ON	X.PoolNumber = Z.PoolNumber_Numeric

		--
		OUTER APPLY	(
						SELECT	Category.Code			as	CategoryCode	
						,		Category.Allocation		as	AllocationPercentage	
						--	
						FROM	(
									VALUES	( 'MBS on Balance Sheet'	, Z.Percentage_BS	)	
									,		( 'MBS Sold In Market'		, Z.Percentage_Sold			) 
									,		( 'MBS Sold to CHT'		, Z.Percentage_CHT			) 
								)	
									Category	( Code , Allocation )	
						--
						WHERE	Category.Allocation > 0.00	
						--	
					)	
						Split	
		--
		--WHERE X.ProductSubcategoryName not like '%- NPL%' and X.ProductCategory_Name not like '%Reverse%mortgage%' and X.ProductSubcategoryName not like '%HELOC%'
		--WHERE X.ProductSubcategoryCode = 19
		WHERE X.IsPastMaturity = 0
		AND X.InLegalAction = 0
		AND X.ProductCategoryID not in ( 6 , 7 )
		--AND X.IsParadigm = 0
		--AND X.IsThirdParty = 0
		--AND X.Company = 7000
		AND X.LoanStatus_Code IN (7,8)
		AND (X.LoanType_Code NOT IN (201 , 250 , 251 , 210 , 240 , 261 , 260)	--	2024-12-19	Pull these revolving loans from NCCF instead since NCCF assumes 100% renewal
		OR X.PaymentDate <= dateadd(day, 30, @EffectiveDate))
		--AND X.IsDerecognized = 0
		--WHERE G.PoolNumber is not null
		Group BY 	X.EffectiveDate
		--,	G.PoolNumber
		,	CASE WHEN Split.CategoryCode IS NOT NULL
					THEN Split.CategoryCode
					WHEN X.PoolNumber IS NOT NULL
					THEN 'MBS on Balance Sheet'
			END				
		,	CASE WHEN datediff(day, @EffectiveDate, X.PaymentDate)	<= 30 AND X.PaymentDate > @EffectiveDate
					THEN 1
					ELSE 0
			END					
		,	X.ProductCategory_Name		
		--,	X.ProductSubcategoryName
		,	X.OSFIType_IsInsured
		,	CASE WHEN X.LoanEncumbranceTypeCategory_ShortName = 'ABCP'
				THEN 1 ELSE 0 END
		,	CASE WHEN X.WarehouseFacility_ShortName IS NOT NULL
				THEN 1 ELSE 0 END

		
		ORDER BY X.ProductCategory_Name
		;

	END TRY		
	BEGIN CATCH		
		SET @ErrorMessage = 'An error was encountered while attempting to extract Concentra Mortgage Inflows. ' 
		GOTO ERROR 
	END CATCH

	--
	--	Extract Concentra Derivative Cashflow
	IF @DEBUG = 1 PRINT dbo.fcn_DebugInfo( 'Extract Concentra Derivative Cashflow value' ) ; 

	BEGIN TRY

	INSERT INTO #lcr_Concentra_Derivative_Cashflow
	(
		Maturity		
	,	Tran#			
	,	Identifier		
	,	Face			
	,	IssueDate		
	,	Type			
	,	Cash			
	,	LineNumber		
	,	Trans			
	,	[Par/Receive]	
	,	Price			
	,	Day				
	)
	SELECT 
		 PaymentDate AS Maturity
		, GLGroup AS Tran#
		--, '' AS Blank1
		, CounterPartySwapID AS Identifier
		, StartingNotional * NotionalMultiplier AS Face
		, StartDate AS IssueDate
		, CASE WHEN LegNumber = 1 THEN 'Fixed'
			 WHEN LegNumber = 2 THEN Swap_FloatingRateIndex_ShortName
		END AS Type
		--,'' AS Blank2
		, CASE WHEN (Swap_DealDirection = 'Pay Fixed' AND LegNumber = 1) OR (Swap_DealDirection = 'Receive Fixed' AND LegNumber = 2) 
			 THEN - StartingNotional * NotionalMultiplier * EffectiveInterestRate
			 ELSE   StartingNotional * NotionalMultiplier * EffectiveInterestRate
			 END AS Cash
		,'Fed Wire' AS LineNumber, TPG_DerivativeID AS Trans, 
		CASE WHEN (Swap_DealDirection = 'Pay Fixed' AND LegNumber = 1) OR (Swap_DealDirection = 'Receive Fixed' AND LegNumber = 2) THEN 'P'
			 ELSE 'R'
			 END AS [Par/Receive]
		--,PaymentDate AS MatDate2
		, ROUND(EffectiveInterestRate / DayCountFraction * 100, 6) AS Price
		, ROUND(DayCountFraction * 365,0) AS Day
		FROM (
		SELECT D.TPG_DerivativeID, D.CounterPartySwapID, D.Swap_DealDirection, D.Counterparty_MarketParticipant_LegalEntity_LongName, D.CounterpartyType, D.Swap_FloatingRateIndex_ShortName,
		DDS.StartingNotional, 
		SUBSTRING(DP.Description, CHARINDEX(' ', DP.Description) + 1, LEN(DP.Description)) AS GLGroup,
		CF.*, MIN(PaymentDate) OVER (PARTITION BY D.TPG_DerivativeID) AS NextPaymentDate
		FROM (
		SELECT	ID, SwapID, TPG_DerivativeID, DealPurpose_Name, CounterPartySwapID, Swap_DealDirection, Counterparty_MarketParticipant_LegalEntity_LongName,Swap_FloatingRateIndex_ShortName,
		CASE WHEN Counterparty_MarketParticipant_LegalEntity_LongName LIKE '%Credit Union%' OR Counterparty_MarketParticipant_LegalEntity_LongName = 'Atlantic Central' OR Counterparty_MarketParticipant_LegalEntity_LongName = 'League Savings and Mortgage'
			 THEN 'CU'
			 ELSE 'B'
		END AS CounterpartyType
		FROM	TA.trade.vw_Deal 
		WHERE   Book_Name = 'Concentra' AND DealType_Name = 'Swap' AND TPG_DerivativeID IS NOT NULL AND CancellationDate IS NULL AND IsActive = 1
		) 
		  D 
		LEFT JOIN TA.trade.DealPurpose DP ON D.DealPurpose_Name = DP.Name
		LEFT JOIN TA.Trade.DealDetail_Swap DDS ON D.ID = DDS.DealID
		OUTER APPLY
		TA.instrument.fcn_Swap_Cashflow 
		( 
			D.SwapID		 --  SwapID					
		,	null 	 --  EffectiveTimestamp		
		,	null 	 --  OverrideCurveTimestamp	
		,	null 	 --  ParallelYieldShock		
		)	
		  CF
		WHERE CF.PaymentDate > @EffectiveDate
		) X 
		WHERE X.PaymentDate = X.NextPaymentDate
		--
		ORDER BY	PaymentDate
				   ,CounterpartyType
				   ,Counterparty_MarketParticipant_LegalEntity_LongName
				   ,TPG_DerivativeID
				   ,CASE WHEN (Swap_DealDirection = 'Pay Fixed' AND LegNumber = 1) OR (Swap_DealDirection = 'Receive Fixed' AND LegNumber = 2) THEN 'P'
						 ELSE 'R'	
					END

		;

	END TRY		
	BEGIN CATCH		
		SET @ErrorMessage = 'An error was encountered while attempting to extract Concentra Derivative Cashflow. ' 
		GOTO ERROR 
	END CATCH

			--	Extract Concentra Mgt Commitment
	IF @DEBUG = 1 PRINT dbo.fcn_DebugInfo( 'Extract Concentra Mgt Commitment value' ) ; 

	BEGIN TRY
		INSERT INTO #lcr_Concentra_Mgt_Commitment
		(
			Loan_Category
		,	TotalCommittedAmount
		)
		SELECT  
			 CASE
				WHEN X.Loan_SubCategory = 'REM' THEN 'Reverse Mortgage'
				WHEN X.Product_Type = 'Alt-A' THEN 'SFR Alt'
				WHEN X.Product_Type = 'Prime' THEN 'SFR Prime'
				WHEN X.Loan_Category = 'Commercial Loans' THEN 'Commercial'
				ELSE 'Consumer'
			END AS Loan_Category
			--, X.Loan_SubCategory
			--, S.EQB_LoanStatus_Code
			--, X.Advance_Date
			--, DATEADD(MONTH, DATEDIFF(MONTH, 0, X.Advance_Date), 0) AS FundingMonth
			, SUM(X.CommittedAmount) TotalCommittedAmount
		--
		FROM (
			SELECT	X.Source
			,		MAX(AsOfDate) MaxAsOfDate
			FROM Concentra.TBSM.vw_Loan_Daily X
			WHERE X.AsOfDate <= @EffectiveDate
			GROUP BY X.Source
		) Y
		LEFT JOIN Concentra.TBSM.vw_Loan_Daily X ON X.AsOfDate = marketinfo.fcn_BusinessDayAdjustment( Y.MaxAsOfDate , 'P' , 'Toronto (Bank)')		-- 2025-06-03
												AND X.Source = Y.Source
		--
		LEFT JOIN Concentra.Loan.LoanStatusMapping S ON LTRIM(RTRIM(X.LoanStatus)) = S.Concentra_LoanStatus
		--
		WHERE X.[Source] = 'Loan_ResPM_Daily'									-- 20250108 change the source to only ResPM
			AND X.LoanStatus IS NOT NULL
			--and X.Loan_SubCategory = 'MTG'
			AND S.EQB_LoanStatus_Code BETWEEN 3 AND 6
			--
			AND X.Advance_Date > @EffectiveDate
			AND	datediff(day, @EffectiveDate, X.Advance_Date) <= 30
		--
		GROUP BY  CASE
						WHEN X.Loan_SubCategory = 'REM' THEN 'Reverse Mortgage'
						WHEN X.Product_Type = 'Alt-A' THEN 'SFR Alt'
						WHEN X.Product_Type = 'Prime' THEN 'SFR Prime'
						WHEN X.Loan_Category = 'Commercial Loans' THEN 'Commercial'
						ELSE 'Consumer'
					END
		--
		ORDER BY  CASE
						WHEN X.Loan_SubCategory = 'REM' THEN 'Reverse Mortgage'
						WHEN X.Product_Type = 'Alt-A' THEN 'SFR Alt'
						WHEN X.Product_Type = 'Prime' THEN 'SFR Prime'
						WHEN X.Loan_Category = 'Commercial Loans' THEN 'Commercial'
						ELSE 'Consumer'
					END
		;

	END TRY		
	BEGIN CATCH		
		SET @ErrorMessage = 'An error was encountered while attempting to extract Concentra Mgt Commitment. ' 
		GOTO ERROR 
	END CATCH

	IF @DEBUG = 1 PRINT dbo.fcn_DebugInfo( 'Extract Concentra Mgt Inflow value' ) ; 

	BEGIN TRY
		INSERT INTO #lcr_Concentra_Mgt_Inflow
		(
			MBSPoolLocation				
		,	PaymentDateInNext30Days		
		,	ProductCategoryname			
		,	ProductSubcategoryname		
		,	OSFIType_IsInsured			
		,	PrincipalPayment_Balloon_CAD
		,	Total_InterestCashflow_CAD	
		,	MBSInterestPayment			
		,	PrincipalPayment_Scheduled	
		)
		SELECT
			CASE WHEN Split.CategoryCode IS NOT NULL
				 THEN Split.CategoryCode
				 WHEN G.PoolNumber IS NOT NULL
				 THEN 'MBS on Balance Sheet'
			END				MBSPoolLocation
		,	CASE WHEN datediff(day, @EffectiveDate, X.PaymentDate)	<= 30 AND X.PaymentDate > @EffectiveDate
				 THEN 1
				 ELSE 0
			END				PaymentDateInNext30Days
		,	CASE WHEN X.ProductCategoryName = 'Loans' AND M.LoanTypeCode IN (33,34)
				 THEN 'Commercial Mortgage'
				 WHEN X.ProductCategoryName = 'Loans' 
				 THEN 'Commercial Loan'
			ELSE X.ProductCategoryName
			END			ProductCategoryName
		,	X.ProductSubcategoryName
		,	X.OSFIType_IsInsured
		,	SUM(PrincipalPayment_Balloon_CAD * coalesce(Split.AllocationPercentage, 1.0000))	PrincipalPayment_Balloon_CAD
		,	SUM(Total_InterestCashflow_CAD * coalesce(Split.AllocationPercentage, 1.0000))		Total_InterestCashflow_CAD
		,	SUM(MBSInterestPayment_Estimated * coalesce(Split.AllocationPercentage, 1.0000))	MBSInterestPayment	
		,	SUM(PrincipalPayment_Scheduled * coalesce(Split.AllocationPercentage, 1.0000))		PrincipalPayment_Scheduled 

		FROM		[Concentra].[loan].[fcn_PortfolioCashflow] 
									(	
										'LCR'			--	@VersionConfiguration_Note
									--
									,	@EffectiveDate	--  @EffectiveDate						
									,	@MonthEnd				--  @MonthEnd			
									--
									,	null			--	@MaximumCashflowDate	
									,	0				--	@ApplyBusinessDayAdjustments	
									--
									)	
										X
		LEFT JOIN Concentra.loan.PortfolioCashflowAttributeGroup G ON G.ID= X.PortfolioCashflowAttributeGroupID
		LEFT JOIN Concentra.Loan.ProductCategoryMapping   M		 ON M.ProductCategoryCode = X.ProductCategoryCode 
														 AND M.LoanTypeCode = X.LoanTypeCode 
														 AND M.ProductSubcategoryCode = X.ProductSubcategoryCode
		--
		LEFT JOIN  (	SELECT	FileDate															--Replace the query by original table after solving the data issue
							,	CMHC_Number
							,	MAX(Coupon)	Coupon					
							,	MAX(Type)	Type
							,	MAX(coalesce(Sold_pct,0.0000))	Sold_pct
						FROM 
						(SELECT MAX(FileDate) MaxFileDate
						FROM Concentra.TBSM.Liabilities_for_Loans_Securitized_Monthly
						WHERE	FileDate <= @EffectiveDate) Y
						LEFT JOIN Concentra.TBSM.Liabilities_for_Loans_Securitized_Monthly X ON X.FileDate = Y.MaxFileDate
						GROUP BY	FileDate, CMHC_Number
					)	Z	ON	G.PoolNumber = Z.CMHC_Number
		--
		OUTER APPLY	(
						SELECT	Category.Code			as	CategoryCode	
						,		Category.Allocation		as	AllocationPercentage	
						--	
						FROM	(
									VALUES	( 'MBS on Balance Sheet'	, (1.0000 - Z.Sold_pct)	)	
									,		( 'MBS Sold In Market'		, Z.Sold_pct			) 
								)	
									Category	( Code , Allocation )	
						--
						WHERE	Category.Allocation > 0.00	
						--	
					)	
						Split	
		--
		WHERE X.ProductSubcategoryName not like '%- NPL%' and X.ProductCategoryName not like '%Reverse%mortgage%' and X.ProductSubcategoryName not like '%HELOC%'
		--WHERE X.ProductSubcategoryCode = 19
		AND		X.IsPastMaturity = 0
		--WHERE G.PoolNumber is not null
		Group BY 	X.EffectiveDate
		--,	G.PoolNumber
		,	CASE WHEN Split.CategoryCode IS NOT NULL
				 THEN Split.CategoryCode
				 WHEN G.PoolNumber IS NOT NULL
				 THEN 'MBS on Balance Sheet'
			END				
		,	CASE WHEN datediff(day, @EffectiveDate, X.PaymentDate)	<= 30 AND X.PaymentDate > @EffectiveDate
				 THEN 1
				 ELSE 0
			END			
		,	CASE WHEN X.ProductCategoryName = 'Loans' AND M.LoanTypeCode IN (33,34)
				 THEN 'Commercial Mortgage'
				 WHEN X.ProductCategoryName = 'Loans' 
				 THEN 'Commercial Loan'
			ELSE X.ProductCategoryName
			END			
		,	X.ProductSubcategoryName
		,	X.OSFIType_IsInsured
		--
		ORDER BY X.ProductSubcategoryName
		;
	END TRY		
	BEGIN CATCH		
		SET @ErrorMessage = 'An error was encountered while attempting to extract Concentra Mgt Inflow. ' 
		GOTO ERROR 
	END CATCH

	--

	IF @DEBUG = 1 PRINT dbo.fcn_DebugInfo( 'Extract EQB MBS Maturities' ) ; 

	BEGIN TRY

	SELECT  @LatestMonthEndAvailable = X.EffectiveDate
	FROM   loan.vw_PortfolioCashflowVersion          X
	WHERE EffectiveDate = EOMONTH(@EffectiveDate, 0)
	AND                     MonthEnd = 1

	SELECT  @RunDate = CASE WHEN @LatestMonthEndAvailable IS NOT NULL              --            
							THEN @LatestMonthEndAvailable               --          default to previous month-end when no recent month-end cashflows available
							ELSE EOMONTH(@EffectiveDate, -1)            --          
							END

	INSERT INTO #lcr_EQB_Securitization_Loan_Maturities
	(
	MonthEnd,
	Issuer,
	MBSPoolLocation,
	MaturityDate,
	BalloonPrincipal
	)
	SELECT    A.MonthEnd
,             A.Issuer
,             A.MBSPoolLocation
,             A.PaymentDate                           MaturityDate
,             SUM(A.BalloonPrincipal)                  BalloonPrincipal
--,           SUM(A.Total_PrincipalCashflow)    TotalPrincipal
--
FROM   (
                     SELECT X.EffectiveDate 
                     ,             X.MonthEnd    
                     --
                     ,             CASE WHEN X.LoanType_Code = '11'
                                         THEN 'FN Multi'
                                         WHEN X.IsThirdParty = 1
                                         THEN 'FN'
                                         WHEN X.IsParadigm = 1
                                         THEN 'Paradigm'
                                         ELSE 'EQB'
                                  END                               Issuer
                     --                                       
                     ,             X.PoolNumber         
                     ,             M.MBSPoolLocation    
                     --
                     ,             X.PaymentDate
                     --
                     --,           SUM( ( X.Total_PrincipalCashflow - X.PrincipalPayment_Balloon ) * coalesce(M.MBSPoolLocation_AllocationPercentage,1.00) )  as  Total_PrincipalCashflow     
                     --,           SUM( X.Total_InterestCashflow  * coalesce(M.MBSPoolLocation_AllocationPercentage,1.00) )  as  Total_InterestCashflow      
                     --,           SUM( X.MaturingBalance     * coalesce(M.MBSPoolLocation_AllocationPercentage,1.00) )  as  MaturingBalance      
                     ,             SUM( X.PrincipalPayment_Balloon   * coalesce(M.MBSPoolLocation_AllocationPercentage,0.00) )  as  BalloonPrincipal
                     --,           SUM( X.Total_PrincipalCashflow    * coalesce(M.MBSPoolLocation_AllocationPercentage,0.00) )  as  Total_PrincipalCashflow
                     --     
                     FROM          loan.fcn_PortfolioCashflow 
                                                (      
                                                       'Liquidity Matching'       --       @VersionConfiguration_Note
                                                --
                                                ,      @RunDate      --  @EffectiveDate                                    
                                                ,      @MonthEnd             --  @MonthEnd              
                                                --
                                                ,      null          --     @MaximumCashflowDate 
                                                ,      0             --       @ApplyBusinessDayAdjustments      
                                                --
                                                )      
                                                       X 
                     --
                     LEFT  JOIN    (
                                                SELECT Mx.PoolNumber_Numeric 
                                                ,             Px.MBSPoolLocation
                                                ,             Cx.MBSPoolLocation_AllocationPercentage 
                                                --     
                                                FROM          securitization.fcn_MBSAllocation ( null , @RunDate )  Mx            
                                                CROSS JOIN    (
                                                                           VALUES ( 'Sold' )    
                                                                           ,             ( 'CHT'       )     
                                                                           ,             ( 'BS'   )       
                                                                     )      
                                                                           Px       ( MBSPoolLocation ) 
                                                OUTER APPLY   (
                                                                           SELECT CASE Px.MBSPoolLocation
                                                                                           WHEN 'Sold' THEN Mx.Percentage_Sold    
                                                                                           WHEN 'CHT' THEN Mx.Percentage_CHT     
                                                                                           WHEN 'BS' THEN Mx.Percentage_BS             
                                                                                         END           
                                                                                  as       MBSPoolLocation_AllocationPercentage     
                                                                     )      
                                                                           Cx     
                                                --     
                                                WHERE  Cx.MBSPoolLocation_AllocationPercentage > 0.00              
                                                --     
                                         )
                                                M      ON     X.PoolNumber = M.PoolNumber_Numeric 
                     --
                     OUTER APPLY   (      
                                         SELECT CASE WHEN DATEDIFF(month,X.EffectiveDate,Z.PaymentMonth) <= 2 
                                                              THEN Z.PaymentDate 
                                                              ELSE Z.PaymentMonth 
                                                       END           as     PaymentDate
                                         ,             Z.PaymentMonth 
                                         FROM   (
                                                              SELECT Ys.PaymentDate       
                                                              ,      dateadd(day,-1,dateadd(month,1,
                                                                     dateadd( day
                                                                           , 1-day(Ys.PaymentDate)
                                                                                  , Ys.PaymentDate )       
                                                                           ))     
                                                                                         as       PaymentMonth 
                                                              --     
                                                              FROM   (
                                                                     SELECT       coalesce(X.PaymentDate_Adjusted,X.PaymentDate)  
                                                                                  as     PaymentDate              
                                                                           )      
                                                                                  Ys     
                                                              --     
                                                       )      
                                                              Z      
                                         )      
                                                Y      
                     --
                     LEFT  JOIN    (
                                                SELECT        distinct      Dx.PoolNumber_Numeric       
                                                FROM          securitization.MBSDerecognition                 Dx
                                               --     
                                                WHERE         Dx.DerecognitionDate <= dateadd(day,5,@RunDate)           
                                                AND                  (
                                                                           Dx.RerecognitionDate > @RunDate
                                                                     OR     Dx.RerecognitionDate IS NULL          
                                                                     )                    
                                                --     
                                         )                    D      
                                                                     --
                                                                     ON       securitization.fcn_PoolNumber_Numeric ( X.PoolNumber ) = D.PoolNumber_Numeric     
                                                                     --     
                     --
                     WHERE            X.PoolNumber IS NOT NULL

                     --
                     GROUP BY      X.EffectiveDate 
                     ,             X.MonthEnd    
                     --
                     ,             CASE WHEN X.LoanType_Code = '11'
                                         THEN 'FN Multi'
                                         WHEN X.IsThirdParty = 1
                                         THEN 'FN'
                                         WHEN X.IsParadigm = 1
                                         THEN 'Paradigm'
                                         ELSE 'EQB'
                                  END           
                     --                                              
                     ,             X.PoolNumber                      
                     ,             M.MBSPoolLocation    
                     --     
                     ,             X.PaymentDate       
                     --
                     HAVING SUM( X.PrincipalPayment_Balloon   * coalesce(M.MBSPoolLocation_AllocationPercentage,0.00) ) > 1.00
                     --     
                     --ORDER BY    max(Y.PaymentMonth   )      
                     --     
              )
                     A
--
GROUP BY      A.EffectiveDate
,             A.MonthEnd
,             A.Issuer
,             A.MBSPoolLocation
,             A.PaymentDate                           
--
ORDER BY      A.PaymentDate
,                    A.Issuer
--
;

	END TRY		
	BEGIN CATCH		
		SET @ErrorMessage = 'An error was encountered while attempting to extract EQB MBS Maturities. ' 
		GOTO ERROR 
	END CATCH


	IF @DEBUG = 1 PRINT dbo.fcn_DebugInfo( 'Extract EQB SecuritizationFlow' ) ; 

	BEGIN TRY

	INSERT INTO #lcr_EQB_Securitization_Cashflows
	(
		SecuritizationFlowType_Name
	,	TransferDate
	,	Amount
	)
	SELECT SecuritizationFlowType_Name 
		, TransferDate_Adjusted as TransferDate 
		, Amount as Amount 
		-- 
		FROM [TA].[cash].[fcn_SecuritizationFlowSchedule_ForLiqMetricModel]  (marketinfo.fcn_BusinessDayAdjustment( @EffectiveDate , 'P' , 'Toronto (Bank)')) 	--  parameter is last business day of previous month
		--
		--WHERE CONVERT(DATE, EffectiveTimestamp) <= @EffectiveDate
		ORDER BY SecuritizationFlowType_Name 
		, TransferDate_Adjusted;

	END TRY		
	BEGIN CATCH		
		SET @ErrorMessage = 'An error was encountered while attempting to extract EQB SecuritizationFlow. ' 
		GOTO ERROR 
	END CATCH

	--

	IF @DEBUG = 1 PRINT dbo.fcn_DebugInfo( 'Estimate largest Net Collateral Flow in past 24-month period.' ) ; 

	BEGIN TRY	
		
		INSERT INTO #lcr_EQB_LargestNetCollateralFlow 
		(
			[Value]		
		--					 
		)	
		
			SELECT MAX(Principal)
			FROM(
				select C.CalendarDate
				, SUM(coalesce(X.Amount_Principal,0.00)) Principal
				from reference.CalendarDate C
				LEFT JOIN collateral.vw_MarginTransaction X	
				ON X.TransactionDate BETWEEN DATEADD(DAY, -29, C.CalendarDate) AND C.CalendarDate
				where C.CalendarDate BETWEEN DATEADD(MONTH, -24, @EffectiveDate) AND @EffectiveDate
				GROUP BY C.CalendarDate
			) X
			--	
			;

		SET @RowCount = @@ROWCOUNT 
		IF @DEBUG = 1 BEGIN PRINT dbo.fcn_DebugInfo( ' rows: ' + convert(varchar(20),@RowCount) ) END ; 

	END TRY		
	BEGIN CATCH		
		SET @ErrorMessage = 'An error was encountered while attempting to estimate largest Net Collateral Flow in past 24-month period.' 
		GOTO ERROR 
	END CATCH	

		--	Undisbursed Commitments	
		--
			
	IF @DEBUG = 1 PRINT dbo.fcn_DebugInfo( 'Estimate Undisbursed Commitments.' ) ; 

	BEGIN TRY	
		
		INSERT INTO #lcr_EQB_UndisbursedCommitments  		
		(
			AllOtherCommitments
		,	LoanCategory
		--					 
		)	

			SELECT	SUM(CASE WHEN X.LoanStatus IN ( 4 , 5 , 6 )		--	2020-03-12	Including LoanStatus 4
							 AND  X.UnderwriterCode != 'PRM'		
							 AND  @EffectiveDate >= '2020-03-11'	
							 AND  X.LoanType != 11					--	2020-07-15	Excluding all Type 11
							 THEN X.TotalAdvance 
							 WHEN X.LoanStatus IN ( 5 , 6 )			
							 AND  X.UnderwriterCode != 'PRM'	
							 AND  X.LoanType != 11					--	2020-07-15	Excluding all Type 11
							 THEN X.TotalAdvance 
							 ELSE 0.00 
						END)					AllOtherCommitments	
			,	X.LoanCategory + IIF(X.UnderwriterCode='DD','-DD','') + IIF(X.LoanPurpose='IR','-IR','') LoanCategory
			--	
			FROM	cash.fcn_FundingActivity 
						(
							dateadd(millisecond,-5,
							 dateadd(day,1,
							  convert(datetime,@EffectiveDate) 
							   ))		--	EffectiveTimestamp		
						,	null		--	MinimumFundingDate 	
						,	null		--	MaximumFundingDate	
						)	
							X	
			--
			WHERE	X.FundingDate_Adjusted BETWEEN DATEADD(day,1,@EffectiveDate) 
											   AND DATEADD(day,30,@EffectiveDate)	

			GROUP BY X.LoanCategory + IIF(X.UnderwriterCode='DD','-DD','') + IIF(X.LoanPurpose='IR','-IR','')
			--
			
			--
			;	

		SET @RowCount = @@ROWCOUNT 
		IF @DEBUG = 1 BEGIN PRINT dbo.fcn_DebugInfo( ' rows: ' + convert(varchar(20),@RowCount) ) END ; 

	END TRY		
	BEGIN CATCH		
		SET @ErrorMessage = 'An error was encountered while attempting to estimate Undisbursed Commitments.' 
		GOTO ERROR 
	END CATCH	
	
	--
	
		--
		--	
		--	
		--	2.	MAP INPUT DATA TO EQB LINE NUMBERS
		--	
		--
		--
		
	IF @DEBUG = 1 PRINT dbo.fcn_DebugInfo( '2 - MAP INPUT DATA TO EQB LINE NUMBERS' ) ; 
	
	--
	--
	
	IF @DEBUG = 1 PRINT dbo.fcn_DebugInfo( ' Liquidity Portfolio: ' ) ; 
	
		INSERT INTO #lcr_STAGING_LineItem_Value_EQB 
		(
			LCR_EQBLineItem_Number 
		,	[Value] 
		)	

		SELECT		M.LCR_EQBLineItem_Number	
		--
		,			SUM( CASE WHEN M.ValueType = 'Market'	
							  THEN coalesce(X.MarketValue,0.00)		
							  --
							  WHEN M.ValueType = 'Book' 
							  THEN coalesce(X.BookCost,0.00) 
							  --
							  WHEN M.ValueType = 'Face' 
							  THEN coalesce(X.FaceAmount,0.00) 
							  --
							  WHEN M.ValueType = 'MktValPlusAccrued'
							  THEN coalesce(X.MktValPlusAccrued,0.00) 
							  --
							  ELSE 0.00
							  --
						 END )					--	[Value]		
		--	
		FROM		#lcr_EQB_LiquidityPortfolio	X	
		INNER JOIN	
		( 
			VALUES	(1001, 'MBS' , null , null , null , 'MktValPlusAccrued')
			,		(1002, 'MBS' , null , null , null , 'MktValPlusAccrued')
			,		(1003, 'Market Investment' , 'NOT Reverse Repo' , 'CMB', null , 'MktValPlusAccrued')
			--	
			,		(1005, 'Market Investment' , 'NOT Reverse Repo' , 'Provincial'	, null , 'MktValPlusAccrued')
			,		(1006, 'Market Investment' , 'Reverse Repo' , 'GOC'	, null , 'MktValPlusAccrued')
			,		(1007, 'Market Investment' , 'Reverse Repo' , 'CMB'	, null , 'MktValPlusAccrued')
			,		(1008, 'Market Investment' , 'Reverse Repo' , 'Provincial'	, null , 'MktValPlusAccrued')
			,		(3001, 'Market Investment' , 'Reverse Repo' , 'GOC'	, null , 'Book')
			,		(3001, 'Market Investment' , 'Reverse Repo' , 'CMB'	, null , 'Book')
			,		(3001, 'Market Investment' , 'Reverse Repo' , 'Provincial'	, null , 'Book')
			,		(3002, 'Market Investment' , 'Reverse Repo' , 'GOC'	, null , 'MktValPlusAccrued')
			,		(3002, 'Market Investment' , 'Reverse Repo' , 'CMB'	, null , 'MktValPlusAccrued')
			,		(3002, 'Market Investment' , 'Reverse Repo' , 'Provincial'	, null , 'MktValPlusAccrued')
			,		(1013, 'Cash' , 'Account Balance' , null , 'TD Cash - Core Account' , 'Face')
			,		(1014, 'Cash' , 'Account Balance' , null , 'Bank of Montreal' , 'Face')

			,		(1015, 'Cash' , 'Account Balance' , null , 'Scotiabank Structured Cash' , 'Face')	
			,		(1016, 'Cash' , 'Account Balance' , null , 'CIBC Special Arrangement CAD' , 'Face')	
			,		(1016, 'Cash' , 'Account Balance' , null , 'CIBC CAD' , 'Face')								-- 2025-05-05 change CIBC CAD to CIBC operate
			--,		(2073, 'Repo', null, null, null, 'Book')
			--,		(2073, 'Market Investment Repo', null, null, null, 'Book')
			--,		(2074, 'Repo', null, null, null, 'Market')
			--,		(2074, 'Market Investment Repo', null, null, null, 'Market')
			--	
		) 
				M	( LCR_EQBLineItem_Number , Category , Subcategory, BondType , LineItem , ValueType )
			--
			ON	X.Category = M.Category 
			AND ( X.Subcategory = M.Subcategory OR M.Subcategory IS NULL OR (M.Subcategory = 'NOT Reverse Repo' AND X.Subcategory != 'Reverse Repo') ) 
			AND ( X.BondType_ShortName = M.BondType OR M.BondType IS NULL ) 
			AND ( X.LineItem = M.LineItem OR M.LineItem IS NULL ) 
			AND ((M.LCR_EQBLineItem_Number = 1001 AND X.Instrument_Issuer = 'EQB') OR (M.LCR_EQBLineItem_Number = 1002 AND coalesce(X.Instrument_Issuer,'') != 'EQB') OR (M.LCR_EQBLineItem_Number NOT IN (1001, 1002)))
			--	
		--	
		GROUP BY	M.LCR_EQBLineItem_Number 
		--	
		;

		IF @DEBUG = 1 PRINT dbo.fcn_DebugInfo( ' Liquidity Portfolio (IsPRA): ' ) ; 
	
		INSERT INTO #lcr_STAGING_LineItem_Value_EQB 
		(
			LCR_EQBLineItem_Number 
		,	[Value] 
		)	

		SELECT		M.LCR_EQBLineItem_Number	
		--
		,			SUM( CASE WHEN M.ValueType = 'Market'	
							  THEN coalesce(X.MarketValue,0.00)		
							  --
							  WHEN M.ValueType = 'Book' 
							  THEN coalesce(X.BookCost,0.00) 
							  --
							  ELSE 0.00
							  --
						 END )					--	[Value]		
		--	
		FROM		#lcr_EQB_LiquidityPortfolio	X	
		INNER JOIN	
		( 
			VALUES	(2073, 'Repo', 0, 'Book')
			,		(2073, 'Market Investment Repo', 0, 'Book')
			,		(2074, 'Repo', 0, 'Market')
			,		(2074, 'Market Investment Repo', 0, 'Market')
			--	
		) 
				M	( LCR_EQBLineItem_Number , Category , IsPRA, ValueType )
			--
			ON	X.Category = M.Category 
			AND X.IsPRA = M.IsPRA
		--	
		GROUP BY	M.LCR_EQBLineItem_Number 
		--	
		;

	--Concentra
	IF @DEBUG = 1 PRINT dbo.fcn_DebugInfo( ' Liquidity Portfolio Concentra: ' ) ; 
	
		INSERT INTO #lcr_STAGING_LineItem_Value_Concentra 
		(
			LCR_EQBLineItem_Number 
		,	[Value] 
		)	

		SELECT		M.LCR_EQBLineItem_Number	
		--
		,			SUM( CASE WHEN M.ValueType = 'Market'	
							  THEN coalesce(X.MarketValue,0.00)		
							  --
							  WHEN M.ValueType = 'Book' 
							  THEN coalesce(X.BookCost,0.00) 
							  --
							  WHEN M.ValueType = 'Face' 
							  THEN coalesce(X.FaceAmount,0.00) 
							  --
							  ELSE 0.00
							  --
						 END )					--	[Value]		
		--	
		FROM		#lcr_Concentra_LiquidityPortfolio	X	
		INNER JOIN	
		( 
			VALUES	(  1001 , 'MBS' , 'Concentra' , null , null , 'Market')
			,		(  1001 , 'MBS' , 'CONFIN' , null , null , 'Market')
			,		(  1001 , 'Pledge Contra' , 'Concentra' , 'MBS' , null , 'Market')
			,		(  1001 , 'Pledge Contra' , 'CONFIN' , 'MBS' , null , 'Market')
			,		(  1002 , 'MBS' , null , null , null , 'Market')
			,		(  1002 , 'Pledge Contra' , null , 'MBS' , null , 'Market')
			,		(  1003 , '1GOVBD' , null , null , 'CMB' , 'Market')
			,		(  1003 , 'Pledge Contra' , null , 'CMB' , null , 'Market')
			,		(  1004 , 'Treasury Bill' , null , null , null , 'Market')
			,		(  1004 , 'Pledge Contra' , null , 'Treasury Bill' , null, 'Market')
			,		(  1005 , '1PROVBD' , null , null , 'Provincial' , 'Market')
			,		(  1005 , 'Pledge Contra' , null , 'Provincial' , null , 'Market')
			,		(  1011 , 'RMBS' , null , null , null , 'Market')
			,		(  1011 , 'Pledge Contra' , null , 'RMBS' , null , 'Market')

		) 
				M	( LCR_EQBLineItem_Number , Category , Issuer_LegalEntity_ShortName, CollateralType, BondType , ValueType )
			--
			ON	X.Category = M.Category 
			AND ( X.Issuer_LegalEntity_ShortName = M.Issuer_LegalEntity_ShortName OR (M.Issuer_LegalEntity_ShortName IS NULL AND X.Issuer_LegalEntity_ShortName IS NULL)  ) 
			AND ( X.BondType_ShortName = M.BondType OR M.BondType IS NULL ) 
			AND ( X.CollateralType = M.CollateralType OR M.CollateralType IS NULL ) 
			--	
		--	
		GROUP BY	M.LCR_EQBLineItem_Number 
		--	
		;


		INSERT INTO #lcr_STAGING_LineItem_Value_Concentra 
		(
			LCR_EQBLineItem_Number 
		,	[Value] 
		)	

		SELECT		M.LCR_EQBLineItem_Number	
		--
		,			SUM( CASE WHEN M.ValueType = 'Market'	
							  THEN coalesce(X.MarketValue,0.00)		
							  --
							  WHEN M.ValueType = 'Book' 
							  THEN coalesce(X.BookCost,0.00) 
							  --
							  WHEN M.ValueType = 'Face' 
							  THEN coalesce(X.FaceAmount,0.00) 
							  --
							  ELSE 0.00
							  --
						 END )					--	[Value]		
		--	
		FROM		#lcr_Concentra_LiquidityPortfolio	X	
		INNER JOIN	
		( 
			VALUES	(1013 , 'Cash' ,'TD High Interest' , 'Market')
			,		(1014 , 'Cash' ,'BMO' , 'Market')
			,		(1015 , 'Cash' ,'scotia High Interest' , 'Market')
			,		(1016 , 'Cash' ,'CIBC Special Arrangements' , 'Market')
			,		(3008, 'Cash', 'TD Operating', 'Market')
			,		(3011, 'Cash', 'CIBC Concentra', 'Market')
			,		(3012, 'Cash', 'National Bank', 'Market')
			,		(3013, 'Cash', 'Saskcentra', 'Market')
			,		(3014, 'Cash', 'Month End Reconc', 'Market')
			,		(3019, 'Cash', 'CentralOne', 'Market')
			,		(3019, 'Cash', 'Collateral', 'Market')				-- 2025-08-011 add Collateral account
		) 
				M	( LCR_EQBLineItem_Number , Category , LineItem, ValueType )
			--
			ON	X.Category = M.Category  
			AND ( X.LineItem = M.LineItem OR M.LineItem IS NULL 
			OR (M.LineItem = 'TD High Interest' AND X.LineItem LIKE 'TD%High%Interest%')
			OR (M.LineItem = 'scotia High Interest' AND X.LineItem LIKE 'scotia%High%Interest%')
			OR (M.LineItem = 'CIBC Special Arrangements' AND X.LineItem LIKE 'CIBC%Special%Arrangements%')
			OR (M.LineItem = 'TD Operating' AND X.LineItem LIKE 'TD%Operating%')
			OR (M.LineItem = 'BMO' AND X.LineItem LIKE 'BMO%')
			OR (M.LineItem = 'CIBC Concentra' AND X.LineItem LIKE 'CIBC%Concentra%')
			OR (M.LineItem = 'National Bank' AND X.LineItem LIKE 'National%Bank%')
			OR (M.LineItem = 'Saskcentra' AND X.LineItem LIKE 'Saskcentra%')
			OR (M.LineItem = 'Month End Reconc' AND X.LineItem LIKE 'Month%End%Reconc%')
			OR (M.LineItem = 'CentralOne' AND X.LineItem LIKE '%Central One%')
			OR (M.LineItem = 'Collateral' AND X.LineItem LIKE '%Collateral%'))
			
		--	
		GROUP BY	M.LCR_EQBLineItem_Number 
		--	
		;
		
	SET @RowCount = @@ROWCOUNT 
	IF @DEBUG = 1 BEGIN PRINT dbo.fcn_DebugInfo( ' rows: ' + convert(varchar(20),@RowCount) ) END ; 

	--
	--

			--
			--	2020-07-03	Corporate bonds by rating
			--

		INSERT INTO #lcr_STAGING_LineItem_Value_EQB 
		(
			LCR_EQBLineItem_Number 
		,	[Value] 
		)	

		SELECT		M.LCR_EQBLineItem_Number	
		--
		,			SUM( coalesce(X.MktValPlusAccrued,0.00) )					--	[Value]		
		--	
		FROM		#lcr_EQB_LiquidityPortfolio	X	
		LEFT  JOIN  marketinfo.CreditRating			R	ON	X.Rating_SP = R.Rating_SP
		LEFT  JOIN  marketinfo.CreditRating			AA	ON	AA.Rating_SP = 'AA-'
		OUTER APPLY	(
						SELECT	CASE WHEN X.Category = 'Market Investment'
									 AND  X.Subcategory = 'Bond'
									 AND  X.BondType_ShortName = 'Covered'
									 AND  R.RankNumber <= AA.RankNumber
									 --AND  coalesce(X.IsFinancial,0) = 0		--	2022-04-08	Excluding Financial instruments
									 THEN 1009
									 WHEN X.Category = 'Market Investment'
									 AND  X.Subcategory = 'Bond'
									 AND  X.BondType_ShortName = 'Corporate'
									 AND  coalesce(R.RankNumber,1000) <= AA.RankNumber
									 AND  coalesce(X.IsFinancial,0) = 0		--	2022-04-08	Excluding Financial instruments 
									 THEN 1010
								END			LCR_EQBLineItem_Number
					)
						M
		--
		WHERE		M.LCR_EQBLineItem_Number IS NOT NULL	
		--
		GROUP BY	M.LCR_EQBLineItem_Number 
		--	
		;

		INSERT INTO #lcr_STAGING_LineItem_Value_EQB 
		(
			LCR_EQBLineItem_Number 
		,	[Value] 
		)	

		SELECT		M.LCR_EQBLineItem_Number	
		--
		,			SUM( coalesce(X.MktValPlusAccrued,0.00) )					--	[Value]		
		--	
		FROM		#lcr_EQB_LiquidityPortfolio	X	
		LEFT  JOIN  marketinfo.CreditRating			R	ON	X.Rating_SP = R.Rating_SP
		LEFT  JOIN  marketinfo.CreditRating			AA	ON	AA.Rating_SP = 'A+'
		LEFT  JOIN  marketinfo.CreditRating			BB	ON	AA.Rating_SP = 'BBB-'
		OUTER APPLY	(
						SELECT	CASE WHEN X.Category = 'Market Investment'
									 AND  X.Subcategory = 'Bond'
									 AND  X.BondType_ShortName = 'Corporate'
									 AND  coalesce(R.RankNumber,1000) >= AA.RankNumber 
									 AND  coalesce(R.RankNumber,1000) <= BB.RankNumber
									 AND  coalesce(X.IsFinancial,0) = 0		
									 THEN 1012
								END			LCR_EQBLineItem_Number
					)
						M
		--
		WHERE		M.LCR_EQBLineItem_Number IS NOT NULL	
		--
		GROUP BY	M.LCR_EQBLineItem_Number 
		--	
		;


		--Concentra
		INSERT INTO #lcr_STAGING_LineItem_Value_Concentra 
		(
			LCR_EQBLineItem_Number 
		,	[Value] 
		)	

		SELECT		M.LCR_EQBLineItem_Number	
		--
		,			SUM( coalesce(X.MarketValue,0.00) )					--	[Value]		
		--	
		FROM		#lcr_Concentra_LiquidityPortfolio	X	
		LEFT  JOIN  marketinfo.CreditRating			R	ON	X.Rating_SP = R.Rating_SP
		LEFT  JOIN  marketinfo.CreditRating			AA	ON	AA.Rating_SP = 'AA-'
		OUTER APPLY	(
						SELECT	CASE WHEN (X.Category = '1CRPBD'
									 --AND  X.Subcategory = 'Bond'
									 AND  X.BondType_ShortName = 'Covered'
									 AND  R.RankNumber <= AA.RankNumber) OR
									 (X.Category = 'Pledge Contra'
									 AND X.CollateralType = '1CRPBD'
									 AND  X.BondType_ShortName = 'Covered'
									 AND  R.RankNumber <= AA.RankNumber)
									 --AND  coalesce(X.IsFinancial,0) = 0		--	2022-04-08	Excluding Financial instruments
									 THEN 1009
									 WHEN (X.Category = '1CRPBD'
									 --AND  X.Subcategory = 'Bond'
									 AND  X.BondType_ShortName = 'Corporate'
									 AND  coalesce(R.RankNumber,1000) <= AA.RankNumber) OR
									 ((X.Category = 'Pledge Contra'
									 AND X.CollateralType = '1CRPBD'
									 AND  X.BondType_ShortName = 'Corporate'
									 AND  R.RankNumber <= AA.RankNumber))
									 --AND  coalesce(X.IsFinancial,0) = 0		--	2022-04-08	Excluding Financial instruments 
									 THEN 1010
								END			LCR_EQBLineItem_Number
					)
						M
		--
		WHERE		M.LCR_EQBLineItem_Number IS NOT NULL	
		--
		GROUP BY	M.LCR_EQBLineItem_Number 
		--	
		;

		INSERT INTO #lcr_STAGING_LineItem_Value_Concentra 
		(
			LCR_EQBLineItem_Number 
		,	[Value] 
		)	

		SELECT		M.LCR_EQBLineItem_Number	
		--
		,			SUM( coalesce(X.MarketValue,0.00) )					--	[Value]		
		--	
		FROM		#lcr_Concentra_LiquidityPortfolio	X	
		LEFT  JOIN  marketinfo.CreditRating			R	ON	X.Rating_SP = R.Rating_SP
		LEFT  JOIN  marketinfo.CreditRating			AA	ON	AA.Rating_SP = 'A+'
		LEFT  JOIN  marketinfo.CreditRating			BB	ON	AA.Rating_SP = 'BBB-'
		OUTER APPLY	(
						SELECT	CASE WHEN (X.Category = '1CRPBD'
									 AND  X.BondType_ShortName = 'Corporate'
									 AND  coalesce(R.RankNumber,1000) >= AA.RankNumber 
									 AND  coalesce(R.RankNumber,1000) <= BB.RankNumber ) OR
									 (X.Category = 'Pledge Contra'
									 AND  X.BondType_ShortName = 'Corporate'
									 AND  coalesce(R.RankNumber,1000) >= AA.RankNumber 
									 AND  coalesce(R.RankNumber,1000) <= BB.RankNumber)
									 THEN 1012
								END			LCR_EQBLineItem_Number
					)
						M
		--
		WHERE		M.LCR_EQBLineItem_Number IS NOT NULL	
		--
		GROUP BY	M.LCR_EQBLineItem_Number 
		--	
		;


		
	SET @RowCount = @@ROWCOUNT 
	IF @DEBUG = 1 BEGIN PRINT dbo.fcn_DebugInfo( ' rows: ' + convert(varchar(20),@RowCount) ) END ; 


	IF @DEBUG = 1 PRINT dbo.fcn_DebugInfo( ' EQB Deposits: ' ) ; 
	
		INSERT INTO #lcr_STAGING_LineItem_Value_EQB 
		(
			LCR_EQBLineItem_Number 
		,	[Value] 
		)	

		SELECT		M.LCR_EQBLineItem_Number
		--
		,			SUM(CASE WHEN M.Insured = 1
							THEN X.InsuredPrincipalCF
							WHEN M.Insured = 0
							THEN X.UninsuredPrincipalCF
							WHEN M.Insured = 2
							THEN X.InsuredPrincipalCF + X.UninsuredPrincipalCF
							END)					--	[Value]		
		--	
		FROM		#lcr_EQB_Deposits	X	
		INNER JOIN	
		( 
			VALUES	(2001, 'Digital Savings' , 'Transactional' , 'CAD' , null , 1)	
			,		(2002, 'Digital Savings', 'NonTransactional / Relationship', 'CAD', null, 1)
			,		(2003, 'Digital GIC - Term', 'NonTransactional / Relationship', 'CAD', '<= 30 Days', 1)
			,		(2003, 'Digital GIC - Cashable', 'NonTransactional / Relationship', 'CAD', '<= 30 Days', 1)
			,		(2003, 'Digital GIC - Term - FHSA', 'NonTransactional / Relationship', 'CAD', '<= 30 Days', 1)
			,		(2003, 'Digital GIC - Term - FHSA', 'NonTransactional / Relationship', 'CAD', '> 30 Days', 1)
			,		(2004, 'NSA - 10 Day', 'NonTransactional / Relationship', 'CAD', null, 1)
			,		(2005, 'NSA - 10 Day (Notice Given)', 'NonTransactional / Relationship', 'CAD', null, 1)
			,		(2006, 'NSA - 30 Day (Notice Given)', 'NonTransactional / Relationship', 'CAD', null, 1)
			,		(2007, 'Digital Savings', 'NonTransactional / NonRelationship', 'CAD', null, 1)
			,		(2008, 'Digital GIC - Term', 'NonTransactional / NonRelationship', 'CAD', '<= 30 Days', 1)
			,		(2008, 'Digital GIC - Cashable', 'NonTransactional / NonRelationship', 'CAD', '<= 30 Days', 1)
			,		(2008, 'Digital GIC - Term - FHSA', 'NonTransactional / NonRelationship', 'CAD', '<= 30 Days', 1)
			,		(2009, 'NSA - 10 Day', 'NonTransactional / NonRelationship', 'CAD', null, 1)
			,		(2010, 'NSA - 10 Day (Notice Given)', 'NonTransactional / NonRelationship', 'CAD', null, 1)
			,		(2011, 'NSA - 30 Day (Notice Given)', 'NonTransactional / NonRelationship', 'CAD', null, 1)
			,		(2012, 'Brokered GIC - Cashable', 'Relationship', 'CAD', '<= 30 Days', 1)
			,		(2013, 'Brokered GIC - Term', 'Relationship', 'CAD', '<= 30 Days', 1)
			,		(2026, 'Brokered HISA', 'Relationship', null, null, 1)
			,		(2014, 'Brokered GIC - Cashable', 'Relationship', 'CAD', '<= 30 Days', 0)
			,		(2015, 'Brokered GIC - Term', 'Relationship', 'CAD', '<= 30 Days', 0)
			,		(2016, 'Digital GIC - Term', null, 'CAD', '<= 30 Days', 0)
			,		(2016, 'Digital GIC - Cashable', null, 'CAD', '<= 30 Days', 0)
			,		(2016, 'Digital GIC - Term - FHSA', null, 'CAD', '<= 30 Days', 0)
			,		(2017, 'Digital Savings', null, 'CAD', null, 0)
			,		(2027, 'Brokered HISA', 'Relationship', null, null, 0)
			,		(2018, 'NSA - 10 Day', null, 'CAD', null, 0)
			,		(2019, 'NSA - 10 Day (Notice Given)', null, 'CAD', null, 0)
			,		(2020, 'NSA - 30 Day (Notice Given)', null, 'CAD', null, 0)
			,		(2021, 'Digital Savings - USD', null, 'USD', null, 2)
			,		(2022, 'Digital Savings - Promo', 'Transactional', 'CAD', null, 1)
			,		(2022, 'Digital Savings - Promo', 'NonTransactional / Relationship', 'CAD', null, 1)
			,		(2022, 'Digital Savings - Registered - Promo', 'Transactional', 'CAD', null, 1)									-- 2025-03-31
			,		(2022, 'Digital Savings - Registered - Promo', 'NonTransactional / Relationship', 'CAD', null, 1)				-- 2025-03-31
			,		(2023, 'Digital Savings - Promo', 'Transactional', 'CAD', null, 0)
			,		(2023, 'Digital Savings - Promo', 'NonTransactional / Relationship', 'CAD', null, 0)
			,		(2023, 'Digital Savings - Registered - Promo', 'Transactional', 'CAD', null, 0)									-- 2025-03-31
			,		(2023, 'Digital Savings - Registered - Promo', 'NonTransactional / Relationship', 'CAD', null, 0)				-- 2025-03-31
			,		(2024, 'Digital Savings - Promo', 'NonTransactional / NonRelationship', 'CAD', null, 1)
			,		(2025, 'Digital Savings - Promo', 'NonTransactional / NonRelationship', 'CAD', null, 0)
			,		(2024, 'Digital Savings - Registered - Promo', 'NonTransactional / NonRelationship', 'CAD', null, 1)			-- 2025-03-31
			,		(2025, 'Digital Savings - Registered - Promo', 'NonTransactional / NonRelationship', 'CAD', null, 0)			-- 2025-03-31
			,		(2028, 'Brokered GIC - Cashable', 'Non-Relationship', 'CAD', '<= 30 Days', 2)
			,		(2029, 'Brokered GIC - Term', 'Non-Relationship', null, '<= 30 Days', 2)
			,		(2032, 'Brokered HISA', 'Non-Relationship', 'CAD', null, 2)
			,		(2033, 'Brokered HISA', 'Non-Relationship', 'USD', null, 2)
			,		(2036, 'NSA - 30 Day', null, 'CAD', null, 2)
			,		(2037, 'Brokered GIC - Cashable', 'Non-Relationship', null, '> 30 Days', 2)
			,		(2038, 'Brokered GIC - Term', 'Non-Relationship', null, '> 30 Days', 2)
			,		(2039, 'Brokered GIC - Cashable', 'Relationship', 'CAD', '> 30 Days', 2)
			,		(2040, 'Digital GIC - Term', null, 'CAD', '> 30 Days', 2)
			,		(2040, 'Digital GIC - Cashable', null, 'CAD', '> 30 Days', 2)
			,		(2064, 'IPC_Investment', null, 'CAD', null, 2)
			--	
		) 
				M	( LCR_EQBLineItem_Number , Product, Relationship, Currency, Payment, Insured)

		ON	X.Product = M.Product
			AND ( X.Relationship = M.Relationship OR M.Relationship IS NULL)
			AND ( X.Currency = M.Currency OR M.Currency IS NULL ) 
			AND ( X.Payment = M.Payment OR M.Payment IS NULL )
		--	
		GROUP BY	M.LCR_EQBLineItem_Number 
		--	
		;

	SET @RowCount = @@ROWCOUNT 
	IF @DEBUG = 1 BEGIN PRINT dbo.fcn_DebugInfo( ' rows: ' + convert(varchar(20),@RowCount) ) END ; 
	--
	IF @DEBUG = 1 PRINT dbo.fcn_DebugInfo( ' Concentra Deposits: ' ) ; 
	
		INSERT INTO #lcr_STAGING_LineItem_Value_Concentra 
		(
			LCR_EQBLineItem_Number 
		,	[Value] 
		)	

		SELECT		M.LCR_EQBLineItem_Number
		--
		,			SUM(CASE WHEN M.Insured = 1
							THEN X.InsuredPrincipalCF
							WHEN M.Insured = 0
							THEN X.UninsuredPrincipalCF
							WHEN M.Insured = 2
							THEN X.InsuredPrincipalCF + X.UninsuredPrincipalCF
							END)					--	[Value]		
		--	
		FROM		#lcr_Concentra_Deposits	X	
		INNER JOIN	
		( 
			VALUES	(  2028, 'Retail_Deposit', 'Redeemable', null, null, '<= 30 Days', 2)
			,		(  2029 , 'Retail_Deposit', 'Non-Redeemable', null, null, '<= 30 Days', 2)
			,		(  2030, 'Retail_Deposit - Credit Union', 'Redeemable', null, null, '<= 30 Days', 2)
			,		(  2031, 'Retail_Deposit - Credit Union', 'Non-Redeemable', null, null, '<= 30 Days', 2)
			,		(  2034, 'Retail_Deposit', 'Demand', null, null, null, 2)
			,		(  2035, 'Retail_Deposit - Credit Union', 'Demand', null, null, null, 2)
			,		(  2037, 'Retail_Deposit', 'Redeemable', null, null, '> 30 Days', 2)
			,		(  2038 , 'Retail_Deposit', 'Non-Redeemable', null, null, '> 30 Days', 2)
			,		(  2041, 'Retail_Deposit - Credit Union', 'Redeemable', null, null, '> 30 Days', 2)
			,		(  2042, 'Retail_Deposit - Credit Union', 'Non-Redeemable', null, null, '> 30 Days', 2)
			,		(  2043 , 'Commercial_Client' , 'Demand' , 'CAD' , 'SB' , null, 1)
			,		(  2044 , 'Commercial_Client' , 'Notice Deposit' , 'CAD' , 'SB' , '<= 30 Days', 1)
			,		(  2044 , 'Commercial_Client' , 'Notice - Atlantic' , 'CAD' , 'SB' , '<= 30 Days', 1)
			,		(  2045 , 'Commercial_Client' , 'Redeemable' , 'CAD' , 'SB' , '<= 30 Days', 1)
			,		(  2045 , 'Commercial_Client' , 'Non-Redeemable' , 'CAD' , 'SB' , '<= 30 Days', 1)
			,		(  2046 , 'Commercial_Client' , 'Demand' , 'CAD' , 'SB' , null, 0)
			,		(  2047 , 'Commercial_Client' , 'Notice Deposit' , 'CAD' , 'SB' , '<= 30 Days', 0)
			,		(  2047 , 'Commercial_Client' , 'Notice - Atlantic' , 'CAD' , 'SB' , '<= 30 Days', 0)
			,		(  2048 , 'Commercial_Client' , 'Redeemable' , 'CAD' , 'SB' , '<= 30 Days', 0)
			,		(  2048 , 'Commercial_Client' , 'Non-Redeemable' , 'CAD' , 'SB' , '<= 30 Days', 0)
			,		(  2049 , 'Commercial_Client' , 'Demand' , 'USD' , 'SB' , null, 2)
			,		(  2050 , 'CreditUnion_Deposit' , 'Notice Deposit' , null , null , '> 30 Days', 2)
			,		(  2050 , 'CreditUnion_Deposit' , 'Notice - Atlantic' , null , null , '> 30 Days', 2)
			,		(  2051 , 'CreditUnion_Deposit' , 'Redeemable' , null , null , '> 30 Days', 2)
			,		(  2051 , 'CreditUnion_Deposit' , 'Non-Redeemable' , null , null , '> 30 Days', 2)
			,		(  2052 , 'Commercial_Client' , 'Notice Deposit' , null , null , '> 30 Days', 2)
			,		(  2052 , 'Commercial_Client' , 'Notice - Atlantic' , null , null , '> 30 Days', 2)
			,		(  2053 , 'Commercial_Client' , 'Redeemable' , null , null , '> 30 Days', 2)
			,		(  2053 , 'Commercial_Client' , 'Non-Redeemable' , null , null , '> 30 Days', 2)
			,		(  2054 , 'CreditUnion_Deposit' , 'Demand' , null , null , null, 1)
			,		(  2055 , 'CreditUnion_Deposit' , 'OrgTerm<=30Day' , null , null , null, 1)
			,		(  2056 , 'CreditUnion_Deposit' , 'Demand' , null , null , null, 0)
			,		(  2057 , 'CreditUnion_Deposit' , 'OrgTerm<=30Day' , null , null , null, 0)
			,		(  2058 , 'Commercial_Client' , 'Demand' , null , 'WS' , null, 1)
			,		(  2059 , 'Commercial_Client' , 'Notice Deposit' , 'CAD' , 'WS' , '<= 30 Days', 1)
			,		(  2059 , 'Commercial_Client' , 'Notice - Atlantic' , 'CAD' , 'WS' , '<= 30 Days', 1)
			,		(  2059 , 'Commercial_Client' , 'Notice Given' , 'CAD' , 'WS' , '<= 30 Days', 1)
			,		(  2060 , 'Commercial_Client' , 'Redeemable' , 'CAD' , 'WS' , '<= 30 Days', 1)
			,		(  2060 , 'Commercial_Client' , 'Non-Redeemable' , 'CAD' , 'WS' , '<= 30 Days', 1)
			,		(  2061 , 'Commercial_Client' , 'Demand' , null , 'WS' , null, 0)
			,		(  2062 , 'Commercial_Client' , 'Notice Deposit' , 'CAD' , 'WS' , '<= 30 Days', 0)
			,		(  2062 , 'Commercial_Client' , 'Notice - Atlantic' , 'CAD' , 'WS' , '<= 30 Days', 0)
			,		(  2062 , 'Commercial_Client' , 'Notice Given' , 'CAD' , 'WS' , '<= 30 Days', 0)
			,		(  2063 , 'Commercial_Client' , 'Redeemable' , 'CAD' , 'WS' , '<= 30 Days', 0)
			,		(  2063 , 'Commercial_Client' , 'Non-Redeemable' , 'CAD' , 'WS' , '<= 30 Days', 0)
			,		(  2065 , 'Commercial_Client' , 'Demand' , null , 'OLE' , null, 2)
			,		(  2066 , 'Commercial_Client' , 'Notice Deposit' , 'CAD' , 'OLE' , '<= 30 Days', 2)
			,		(  2066 , 'Commercial_Client' , 'Notice - Atlantic' , 'CAD' , 'OLE' , '<= 30 Days', 2)
			,		(  2067 , 'Commercial_Client' , 'Redeemable' , 'CAD' , 'OLE' , '<= 30 Days', 2)
			,		(  2067 , 'Commercial_Client' , 'Non-Redeemable' , 'CAD' , 'OLE' , '<= 30 Days', 2)
			,		(  2068 , 'CreditUnion_Deposit' , 'Notice Deposit' , null , null , '<= 30 Days', 2)
			,		(  2068 , 'CreditUnion_Deposit' , 'Notice - Atlantic' , null , null , '<= 30 Days', 2)
			,		(  2069 , 'CreditUnion_Deposit' , 'Redeemable' , null , null , '<= 30 Days', 2)
			,		(  2070 , 'CreditUnion_Deposit' , 'Non-Redeemable' , null , null , '<= 30 Days', 2)
			--	
			--	
		) 
				M	( LCR_EQBLineItem_Number , SourceTable , Category, Currency , DepositType , Payment, Insured)
			--
			ON	X.SourceTable = M.SourceTable 
			AND ( X.Category = M.Category OR M.Category IS NULL OR (M.Category = 'OrgTerm<=30Day' AND X.Category LIKE '%OrgTerm<=30Day%')) 
			AND ( X.Currency = M.Currency OR M.Currency IS NULL ) 
			AND ( X.DepositType = M.DepositType OR M.DepositType IS NULL )
			AND ( X.Payment = M.Payment OR M.Payment IS NULL ) 
			--	
		--	
		GROUP BY	M.LCR_EQBLineItem_Number 
		--	
		;

	INSERT INTO #lcr_STAGING_LineItem_Value_Concentra 
		(
			LCR_EQBLineItem_Number 
		,	[Value] 
		)	

	SELECT		M.LCR_EQBLineItem_Number
		--
		,			SUM(CASE WHEN M.Insured = 1
							THEN X.InsuredInterestCF
							WHEN M.Insured = 0
							THEN X.UninsuredInterestCF
							WHEN M.Insured = 2
							THEN X.InsuredInterestCF + X.UninsuredInterestCF
							END)					--	[Value]		
		--	
		FROM		#lcr_Concentra_Deposits	X	
		INNER JOIN	
		( 
			VALUES	(  2084, 'Retail_Deposit', null, null, null, '<= 30 Days', 2)
			,		(  2085, 'Retail_Deposit - Credit Union', null, null, null, '<= 30 Days', 2)
			,		(  2087, 'CreditUnion_Deposit' , null , null , null , '<= 30 Days', 2)
			,		(  2088, 'Commercial_Client' , null , null , null , '<= 30 Days', 2)
		) 
			M	( LCR_EQBLineItem_Number , SourceTable , Category, Currency , DepositType , Payment, Insured)
		--
		ON	X.SourceTable = M.SourceTable 
		AND ( X.Category = M.Category OR M.Category IS NULL ) 
		AND ( X.Currency = M.Currency OR M.Currency IS NULL ) 
		AND ( X.DepositType = M.DepositType OR M.DepositType IS NULL )
		AND ( X.Payment = M.Payment OR M.Payment IS NULL ) 
		--	
	--	
	GROUP BY	M.LCR_EQBLineItem_Number
	--
	--
	SET @RowCount = @@ROWCOUNT 
	IF @DEBUG = 1 BEGIN PRINT dbo.fcn_DebugInfo( ' rows: ' + convert(varchar(20),@RowCount) ) END ; 


	IF @DEBUG = 1 PRINT dbo.fcn_DebugInfo( 'Securitization Cashflows: ' ) ; 


	
		INSERT INTO #lcr_STAGING_LineItem_Value_EQB 
		(
			LCR_EQBLineItem_Number	
		,	[Value]		
		)
		SELECT  2083, 
			SUM(Amount) 
		FROM #lcr_EQB_Securitization_Cashflows 
		--WHERE MONTH(TransferDate) = MONTH(@EffectiveDate)
		WHERE TransferDate BETWEEN DATEADD(DAY, 1, @EffectiveDate) AND DATEADD(DAY, 30, @EffectiveDate)
		AND SecuritizationFlowType_Name = 'FNFLP';

		-- if there's no amount in Securitization_Cashflows then we using MBS_Maturities
		IF NOT EXISTS (SELECT 1 FROM #lcr_STAGING_LineItem_Value_EQB WHERE LCR_EQBLineItem_Number = 2083)
		OR EXISTS (SELECT 1 FROM #lcr_STAGING_LineItem_Value_EQB WHERE LCR_EQBLineItem_Number = 2083 AND [Value] IS NULL)
		BEGIN

		DELETE FROM #lcr_STAGING_LineItem_Value_EQB WHERE LCR_EQBLineItem_Number = 2083;

		INSERT INTO #lcr_STAGING_LineItem_Value_EQB 
		(
			LCR_EQBLineItem_Number	
		,	[Value]		
		)
		SELECT  2083, 
			SUM(X.BalloonPrincipal) * 0.5 
		FROM #lcr_EQB_Securitization_Loan_Maturities X
		--WHERE X.MaturityDate BETWEEN DATEADD(DAY, -30, @EffectiveDate) AND @EffectiveDate
		WHERE X.MaturityDate BETWEEN DATEADD(DAY, 1, @EffectiveDate) AND DATEADD(DAY, 30, @EffectiveDate);		-- 2025-05-02 change the date same with #lcr_EQB_Securitization_Cashflows for consistency
		END
		
	
	SET @RowCount = @@ROWCOUNT 
	IF @DEBUG = 1 BEGIN PRINT dbo.fcn_DebugInfo( ' rows: ' + convert(varchar(20),@RowCount) ) END ; 

	IF @DEBUG = 1 PRINT dbo.fcn_DebugInfo( 'Mortgage Inflows: ' ) ; 
	
		INSERT INTO #lcr_STAGING_LineItem_Value_EQB 
		(
			LCR_EQBLineItem_Number	
		,	[Value]		
		)
		SELECT	M.LCR_EQBLineItem_Number	
		,		SUM(CASE WHEN M.Payment = 'Balloon'
						THEN X.PrincipalPayment_Balloon_CAD
						WHEN M.Payment = 'Cashflow'
						THEN X.Total_InterestCashflow_CAD
						WHEN M.Payment = 'MBS'
						THEN X.MBSInterestPayment
						WHEN M.Payment = 'Scheduled'
						THEN X.PrincipalPayment_Scheduled
						END)	--	[Value]			
		--	
		FROM	#lcr_EQB_Mortgage_Inflows	X	
		INNER JOIN	
		(
			VALUES	(3003, 1, 0, 0, 'SFR', 'Balloon')
				,	(3003, 1, 0, 0, 'SFR Prime', 'Balloon')
				,	(3004, 1, 0, 0, 'SFR Prime', 'Scheduled')
				,	(3004, 1, 0, 0, 'SFR', 'Scheduled')
				,	(3004, 1, 0, 0, 'SFR Prime', 'Cashflow')
				,	(3004, 1, 0, 0, 'SFR', 'Cashflow')
				,	(3004, 1, 0, 0, 'Multi Family', 'Scheduled')
				,	(3004, 1, 0, 0, 'Multi Family', 'Cashflow')
				--,	(109, 1, 0, 0, 'NOT SFR', 'Balloon')
				--,	(110, 1, 0, 0, 'NOT SFR', 'Scheduled')
				--,	(110, 1, 0, 0, 'NOT SFR', 'Cashflow')
				,	(3017, 1, 0, 0, 'Commercial', 'Balloon')
				,	(3017, 1, 0, 0, 'Construction', 'Balloon')
				,	(3017, 1, 0, 0, 'Commercial', 'Scheduled')
				,	(3017, 1, 0, 0, 'Construction', 'Scheduled')
				,	(3017, 1, 0, 0, 'Commercial', 'Cashflow')
				,	(3017, 1, 0, 0, 'Construction', 'Cashflow')
			--
		)	
			M	(LCR_EQBLineItem_Number, PaymentDateInNext30Days, InABCP, InWarehouse, ProductCategory_Name, Payment)
			--
			ON	X.MBSPoolLocation IS NULL
			AND X.PaymentDateInNext30Days = M.PaymentDateInNext30Days
			AND X.InABCP = M.InABCP
			AND X.InWarehouse = M.InWarehouse
			AND (X.ProductCategory_Name = M.ProductCategory_Name OR 
				(M.ProductCategory_Name = 'NOT SFR' AND X.ProductCategory_Name NOT LIKE '%SFR%'))
			--
		--
		GROUP BY	M.LCR_EQBLineItem_Number	
		--	
		;
		
	SET @RowCount = @@ROWCOUNT 
	IF @DEBUG = 1 BEGIN PRINT dbo.fcn_DebugInfo( ' rows: ' + convert(varchar(20),@RowCount) ) END ; 

	--
	--
	IF @DEBUG = 1 PRINT dbo.fcn_DebugInfo( 'Concentra Mortgage Inflows: ' ) ; 
	
		INSERT INTO #lcr_STAGING_LineItem_Value_Concentra 
		(
			LCR_EQBLineItem_Number	
		,	[Value]		
		)
		SELECT	M.LCR_EQBLineItem_Number	
		,		SUM(CASE WHEN M.Payment = 'Balloon'
						THEN X.PrincipalPayment_Balloon_CAD
						WHEN M.Payment = 'Cashflow'
						THEN X.Total_InterestCashflow_CAD
						WHEN M.Payment = 'MBS'
						THEN X.MBSInterestPayment
						WHEN M.Payment = 'Scheduled'
						THEN X.PrincipalPayment_Scheduled
						END)	--	[Value]			
		--	
		FROM	#lcr_Concentra_Mgt_Inflow	X	
		INNER JOIN	
		(
			VALUES	(3003, 'All', 1, 'Retail', 'Balloon')
			,		(3003, 'All', 1, 'Consumer', 'Balloon')
			,		(3003, 'MBS', 1, NULL, 'Balloon')
			,		(3004, 'All', 1, 'Retail', 'Scheduled')
			,		(3004, 'All', 1, 'Consumer', 'Scheduled')
			,		(3004, 'MBS', 1, NULL, 'Scheduled')
			,		(3004, 'All', 1, 'Retail', 'Cashflow')
			,		(3004, 'All', 1, 'Consumer', 'Cashflow')
			,		(3004, 'MBS', 1, NULL, 'Cashflow')
			,		(3005, NULL, 1, 'Commercial', 'Balloon')
			,		(3006, 'All', 1, 'Commercial', 'Scheduled')
			,		(3006, 'All', 1, 'Commercial', 'Cashflow')
			,		(2083, 'MBS Sold', 1, NULL, 'Balloon')
			,		(2083, 'MBS Sold', 1, NULL, 'MBS')
			--
		)	
			M	(LCR_EQBLineItem_Number, MBSPoolLocation, PaymentDateInNext30Days, ProductCategory_Name, Payment)
			--
			ON	((X.MBSPoolLocation IS NULL AND  M.MBSPoolLocation IS NULL)
			OR (M.MBSPoolLocation = 'MBS' AND X.MBSPoolLocation like '%MBS%')
			OR (M.MBSPoolLocation = 'MBS Sold' AND X.MBSPoolLocation like 'MBS%Sold%')
			OR M.MBSPoolLocation = 'All')
			AND X.PaymentDateInNext30Days = M.PaymentDateInNext30Days
			AND (X.ProductCategoryname = M.ProductCategory_Name OR M.ProductCategory_Name IS NULL
			OR (M.ProductCategory_Name = 'Retail' AND X.ProductCategoryname like '%Retail%')
			OR (M.ProductCategory_Name = 'Consumer' AND X.ProductCategoryname like '%Consumer%')
			OR (M.ProductCategory_Name = 'Commercial' AND X.ProductCategoryname like '%Commercial%'))
			--
		--
		GROUP BY	M.LCR_EQBLineItem_Number	
		--	
		;
		
	SET @RowCount = @@ROWCOUNT 
	IF @DEBUG = 1 BEGIN PRINT dbo.fcn_DebugInfo( ' rows: ' + convert(varchar(20),@RowCount) ) END ; 
	--
	--

	IF @DEBUG = 1 PRINT dbo.fcn_DebugInfo( ' Other Items EQB: ' ) ; 
	
		INSERT INTO #lcr_STAGING_LineItem_Value_EQB 
		(
			LCR_EQBLineItem_Number	
		,	[Value]		
		)	
		
			SELECT	2071					 --	LCR_EQBLineItem_Number	
			,		SUM(N.PrincipalPaymentIn30Days)	 --	[Value]				
			--	
			FROM	#lcr_EQB_DepositNoteMaturities	N	
			--
			WHERE	N.Name LIKE '%Deposit Note%'
			AND		N.MaturityDate > @EffectiveDate
			AND		N.MaturityDate <= DATEADD(DAY, 30, @EffectiveDate)
	--		--

	--
			UNION ALL

			SELECT	2072					 --	LCR_EQBLineItem_Number	
			,		SUM(N.PrincipalPaymentIn30Days)	 --	[Value]				
			--	
			FROM	#lcr_EQB_DepositNoteMaturities	N	
			--
			WHERE	N.Name LIKE '%BDN%'
			AND		N.MaturityDate > @EffectiveDate
			AND		N.MaturityDate <= DATEADD(DAY, 30, @EffectiveDate)
			AND		N.IssueDate  <= @EffectiveDate

			UNION ALL

			SELECT	2078					 --	LCR_EQBLineItem_Number	
			,		SUM(N.PrincipalPaymentIn30Days)	 --	[Value]				
			--	
			FROM	#lcr_EQB_DepositNoteMaturities	N	
			--
			WHERE	N.Name LIKE '%Covered%Bond%'
			AND		N.MaturityDate > @EffectiveDate
			AND		N.MaturityDate <= DATEADD(DAY, 30, @EffectiveDate)

			UNION ALL

			SELECT	2080					 --	LCR_EQBLineItem_Number	
			,		SUM(N.FaceValue)	 --	[Value]				
			--	
			FROM	#lcr_EQB_DepositNoteMaturities	N	
			--
			WHERE	N.Name LIKE '%Deposit Note%'
			AND		N.IssueDate <= @EffectiveDate
			AND		N.MaturityDate > DATEADD(DAY, 30, @EffectiveDate)

			UNION ALL

			SELECT	2081					 --	LCR_EQBLineItem_Number	
			,		SUM(N.FaceValue)	 --	[Value]				
			--	
			FROM	#lcr_EQB_DepositNoteMaturities	N	
			--
			WHERE	N.Name LIKE '%BDN%'
			AND		N.IssueDate <= @EffectiveDate
			AND		N.MaturityDate > DATEADD(DAY, 30, @EffectiveDate)

			UNION ALL

			SELECT	2082					 --	LCR_EQBLineItem_Number	
			,		SUM(N.FaceValue)	 --	[Value]				
			--	
			FROM	#lcr_EQB_DepositNoteMaturities	N	
			--
			WHERE	N.Name LIKE '%Covered%Bond%'
			AND		N.IssueDate <= @EffectiveDate
			AND		N.MaturityDate > DATEADD(DAY, 30, @EffectiveDate)

			UNION ALL
	

			SELECT		2084
			--
			,			SUM(X.UninsuredInterestCF + X.InsuredInterestCF)				--	[Value]		
			--	
			FROM		#lcr_EQB_Deposits	X
			--
			WHERE		X.Payment = '<= 30 Days'
			AND			X.Product NOT LIKE '%FHSA%'

			UNION ALL

			SELECT	2086					 --	LCR_EQBLineItem_Number	
			,		SUM(N.InterestPaymentIn30Days)	 --	[Value]				
			--	
			FROM	#lcr_EQB_DepositNoteMaturities	N	

			UNION ALL

			SELECT	3007					 --	LCR_EQBLineItem_Number	
			,		SUM(X.FaceAmount)	 --	[Value]				
			--	
			FROM	#lcr_EQB_LiquidityPortfolio	X
			WHERE X.Category = 'Cash'
			AND	X.LineItem Like '%Bennington%'

			UNION ALL

			SELECT	3008					 --	LCR_EQBLineItem_Number	
			,		SUM(X.FaceAmount)	 --	[Value]				
			--	
			FROM	#lcr_EQB_LiquidityPortfolio	X
			WHERE X.Category = 'Cash'
			AND	X.LineItem Like '%TD%'
			AND X.Instrument_Issuer = 'XX'

			UNION ALL

			SELECT	3009					 --	LCR_EQBLineItem_Number	
			,		SUM(X.FaceAmount)	 --	[Value]				
			--	
			FROM	#lcr_EQB_LiquidityPortfolio	X
			WHERE X.Category = 'Cash'
			AND	X.LineItem Like '%Scotia%'
			AND X.Instrument_Issuer = 'XX'

			UNION ALL

			SELECT	3010					 --	LCR_EQBLineItem_Number	
			,		SUM(X.FaceAmount)	 --	[Value]				
			--	
			FROM	#lcr_EQB_LiquidityPortfolio	X
			WHERE X.Category = 'Cash'
			AND	X.LineItem Like '%BMO%clearing%'

			UNION ALL

			SELECT	3014					 --	LCR_EQBLineItem_Number	
			,		SUM(X.FaceAmount)	 --	[Value]				
			--	
			FROM	#lcr_EQB_LiquidityPortfolio	X
			WHERE X.Category = 'Cash'
			AND	X.LineItem Like '%Miscellaneous%'

			UNION ALL

			SELECT	3015					 --	LCR_EQBLineItem_Number	
			,		SUM(X.FaceAmount)	 --	[Value]				
			--	
			FROM	#lcr_EQB_LiquidityPortfolio	X
			WHERE X.Category = 'Cash'
			AND	X.LineItem Like '%ATB%'

			UNION ALL

			SELECT	3016					 --	LCR_EQBLineItem_Number	
			,		SUM(X.FaceAmount)	 --	[Value]				
			--	
			FROM	#lcr_EQB_LiquidityPortfolio	X
			WHERE X.Category = 'Market Investment'
			AND	X.Subcategory = 'Cashable Deposit'
			AND X.RedeemableDate <= DATEADD(DAY, 30, @EffectiveDate)

			UNION ALL	

			SELECT	2077					--	LCR_EQBLineItem_Number	
			,		X.[Value] 				--	[Value]	
			FROM	#lcr_EQB_LargestNetCollateralFlow	 X

			UNION ALL	
		
			SELECT	2079					--	LCR_EQBLineItem_Number	
			,		SUM(X.AllOtherCommitments)	--	[Value]		
			FROM	#lcr_EQB_UndisbursedCommitments	 X	
			WHERE	X.LoanCategory != 'Commercial' 
		
	--	--
	--	

	SET @RowCount = @@ROWCOUNT 
	IF @DEBUG = 1 BEGIN PRINT dbo.fcn_DebugInfo( ' rows: ' + convert(varchar(20),@RowCount) ) END ; 
	--
	--
	IF @DEBUG = 1 PRINT dbo.fcn_DebugInfo( ' Other Items in Concentra: ' ) ; 
	
		INSERT INTO #lcr_STAGING_LineItem_Value_Concentra
		(
			LCR_EQBLineItem_Number	
		,	[Value]		
		)	
		
			SELECT	2076					 --	LCR_EQBLineItem_Number	
			,		SUM(-X.Cash)	 --	[Value]				
			--	
			FROM	#lcr_Concentra_Derivative_Cashflow	X	
			--
			WHERE	[Par/Receive] = 'P'
	--
			UNION ALL

			SELECT	3018					 --	LCR_EQBLineItem_Number	
			,		SUM(X.Cash)	 --	[Value]				
			--	
			FROM	#lcr_Concentra_Derivative_Cashflow	X	
			--
			WHERE	[Par/Receive] = 'R'

			UNION ALL

			SELECT 2079
			,		SUM(X.TotalCommittedAmount)
			--
			FROM #lcr_Concentra_Mgt_Commitment	X

	--
	--
	
		--
		--	Check that all LCR_EQBLineItem_Number values exist in LCR_EQBLineItem table	
		--	

		IF EXISTS ( SELECT		null 
					FROM		#lcr_STAGING_LineItem_Value_EQB	X 
					LEFT  JOIN	liquidity.LCR_EQBLineItem_Daily		L	ON	X.LCR_EQBLineItem_Number = L.Number 
					WHERE		L.ID IS NULL )		
		BEGIN	
			IF @DEBUG = 1 
			BEGIN 
				SELECT		'Invalid LCR_EQBLineItem_Number reference: '	Information		
				--	
				,			X.LCR_EQBLineItem_Number	
				,			X.[Value]	
				--	 
				FROM		#lcr_STAGING_LineItem_Value_EQB	X 
				LEFT  JOIN	liquidity.LCR_EQBLineItem_Daily		L	ON	X.LCR_EQBLineItem_Number = L.Number 
				--	
				WHERE		L.ID IS NULL	
				--
				ORDER BY	X.LCR_EQBLineItem_Number	
				--	
				;
			END 

			SET @ErrorMessage = 'At least one staged LCR_EQBLineItem_Number value is unrecognized.' 
			GOTO ERROR 
		END		
					
	--
	--
		
			INSERT INTO #lcr_STAGING_LineItem_Value_EQB 
			(
				LCR_EQBLineItem_Number 
			,	[Value]		
			)	

			SELECT	-1		--	LCR_EQBLineItem_Number	
			,		CASE WHEN Y.[Value] < 0.00 
						 THEN X.[Value]
						 --
						 ELSE X.[Value] 
							/ Y.[Value] 
						 --
					END		--	[Value]		
			--	
			FROM		#lcr_STAGING_LineItem_Value_EQB	X	
			INNER JOIN	#lcr_STAGING_LineItem_Value_EQB	Y	
							--
							ON	X.LCR_EQBLineItem_Number = -3 
							AND Y.LCR_EQBLineItem_Number = -2
							--
			--	
			;	
			
		SET @RowCount = @@ROWCOUNT 
		IF @DEBUG = 1 BEGIN PRINT dbo.fcn_DebugInfo( ' rows: ' + convert(varchar(20),@RowCount) ) END ; 

	--
	--

	IF @DEBUG = 1 PRINT dbo.fcn_DebugInfo( ' Check NULL in EQB: ' ) ;		-- 2025-01-20
	
	INSERT INTO #lcr_Check_NULL_EQB(LCR_EQBLineItem_Number)
	VALUES (1001)
		, (1002)
		, (1003)
		, (1005)
		, (1009)
		, (1013)
		, (1014)
		, (1015)
		, (2001)
		, (2002)
		, (2003)
		, (2004)
		, (2005)
		, (2006)
		, (2007)
		, (2008)
		, (2009)
		, (2010)
		, (2011)
		, (2016)
		, (2017)
		, (2018)
		, (2019)
		, (2020)
		, (2021)
		, (2022)
		, (2023)
		, (2024)
		, (2025)
		, (2026)
		, (2027)
		, (2028)
		, (2029)
		, (2032)
		, (2033)
		, (2036)
		, (2037)
		, (2038)
		, (2040)
		, (2064)
		, (2072)
		, (2077)
		, (2081)
		, (2082)
		, (2083)
		, (2084)
		, (2086)
		, (3003)
		, (3004)
		, (3007)
		, (3008)
		, (3009)
		, (3010)
		, (3015)
		, (3017)

	-- update values into temp table 
	BEGIN TRY
		UPDATE #lcr_Check_NULL_EQB
		SET	Value =  X.Value
		FROM #lcr_STAGING_LineItem_Value_EQB X
		INNER JOIN #lcr_Check_NULL_EQB Y on X.LCR_EQBLineItem_Number = Y.LCR_EQBLineItem_Number
	END TRY		
	BEGIN CATCH		
		SET @ErrorMessage = 'An error was encountered while checking NULL in EQB. ' 
		GOTO ERROR 
	END CATCH

	SET @NULL_Message_EQB = @NULL_Message_EQB + (SELECT (
			SELECT ',' + Convert(varchar(100),LCR_EQBLineItem_Number) AS [text()]
			FROM #lcr_Check_NULL_EQB
			WHERE Value IS NULL
			ORDER BY LCR_EQBLineItem_Number
			FOR XML PATH('')
		) AS 'Numbers');


	SET @RowCount = @@ROWCOUNT 
	IF @DEBUG = 1 BEGIN PRINT dbo.fcn_DebugInfo( ' rows: ' + convert(varchar(20),@RowCount) ) END ;

	IF @DEBUG = 1 PRINT dbo.fcn_DebugInfo( ' Check NULL in Concentra: ' ) ; 

	INSERT INTO #lcr_Check_NULL_Concentra (LCR_EQBLineItem_Number)
		VALUES	(1001)
				, (1002)
				, (1003)
				, (1013)
				, (1014)
				, (1015)
				, (1016)
				, (2028)
				, (2029)
				, (2030)
				, (2031)
				, (2034)
				, (2035)
				, (2037)
				, (2038)
				, (2041)
				, (2042)
				, (2043)
				, (2046)
				, (2050)
				, (2051)
				, (2054)
				, (2056)
				, (2061)
				, (2065)
				, (2069)
				, (2070)
				, (2083)
				, (2084)
				, (2085)
				, (2087)
				, (2088)
				, (3003)
				, (3004)
				, (3005)
				, (3006)
				, (3008)
				, (3011)
				, (3013)
				, (3019)

	BEGIN TRY
		UPDATE #lcr_Check_NULL_Concentra
		SET	Value =  X.Value
		FROM #lcr_STAGING_LineItem_Value_Concentra X
		INNER JOIN #lcr_Check_NULL_Concentra Y on X.LCR_EQBLineItem_Number = Y.LCR_EQBLineItem_Number

	END TRY		
	BEGIN CATCH		
		SET @ErrorMessage = 'An error was encountered while checking NULL in Concentra. ' 
		GOTO ERROR 
	END CATCH

	SET @NULL_Message_Concentra = @NULL_Message_Concentra + (SELECT (
			SELECT ',' + Convert(varchar(100),LCR_EQBLineItem_Number) AS [text()]
			FROM #lcr_Check_NULL_Concentra
			WHERE Value IS NULL
			ORDER BY LCR_EQBLineItem_Number
			FOR XML PATH('')
		) AS 'Numbers');

	SET @RowCount = @@ROWCOUNT 
	IF @DEBUG = 1 BEGIN PRINT dbo.fcn_DebugInfo( ' rows: ' + convert(varchar(20),@RowCount) ) END ;

	--
	--

	IF @DEBUG = 1 PRINT dbo.fcn_DebugInfo( '@Mode = ''' + @Mode + '''.' ) ; 

	--
	--

	IF @Mode = 'VIEW' 
	BEGIN	

		IF @DEBUG = 1 PRINT dbo.fcn_DebugInfo( 'Display results.' ) ; 
	

			SELECT		@CurrentTimestamp	as	RunTimestamp	 
			,			@EffectiveDate		as	EffectiveDate	
			,			@MonthEnd			as	MonthEnd		
			--		
			,			L.Number	as	LCR_EQBLineItem_Number
			,			X.[Value]	as	EQB_Value
			,			Y.[Value]	as	Concentra_Value					
			,			L.Note		as	LCR_EQBLineItem_Note
			,			coalesce(X.[Value],0.0000) / 1000.0000	as	EQB_Value_Thousands
			,			coalesce(Y.[Value],0.0000) / 1000.0000	as	Concentra_Value_Thousands 
			FROM		liquidity.LCR_EQBLineItem_Daily		L			
			LEFT  JOIN	#lcr_STAGING_LineItem_Value_EQB	X	ON	L.Number = X.LCR_EQBLineItem_Number 
			LEFT  JOIN  #lcr_STAGING_LineItem_Value_Concentra	Y	ON	L.Number = Y.LCR_EQBLineItem_Number
			WHERE		L.Number >= 1   
			--
			ORDER BY	L.Number	ASC		
			--
			;

			


																			

		SET @RowCount = @@ROWCOUNT 
		IF @DEBUG = 1 BEGIN PRINT dbo.fcn_DebugInfo( ' rows: ' + convert(varchar(20),@RowCount) ) END ; 

	END 
	ELSE IF @Mode = 'TEMP' 
	BEGIN	
		
		IF @DEBUG = 1 PRINT dbo.fcn_DebugInfo( 'Add results to provided temporary table.' ) ; 
		
		BEGIN TRY	

			INSERT INTO #usp_Calculate_LCR_Output
			(
				RunTimestamp,				
			--								
				EffectiveDate,
				MonthEnd,
				LCR_EQBLineItem_Number,
				EQB_Value,
				Concentra_Value,
				LCR_EQBLineItem_Note,
				EQB_Value_Thousands,
				Concentra_Value_Thousands				
			--								
			)	

			SELECT		@CurrentTimestamp	as	RunTimestamp	 
			,			@EffectiveDate		as	EffectiveDate	
			,			@MonthEnd			as	MonthEnd		
			--		
			,			L.Number	as	LCR_EQBLineItem_Number
			,			X.[Value]	as	EQB_Value
			,			Y.[Value]	as	Concentra_Value					
			,			L.Note		as	LCR_EQBLineItem_Note
			,			coalesce(X.[Value],0.0000) / 1000.0000	as	EQB_Value_Thousands
			,			coalesce(Y.[Value],0.0000) / 1000.0000	as	Concentra_Value_Thousands 
			FROM		liquidity.LCR_EQBLineItem_Daily		L			
			LEFT  JOIN	#lcr_STAGING_LineItem_Value_EQB	X	ON	L.Number = X.LCR_EQBLineItem_Number 
			LEFT  JOIN  #lcr_STAGING_LineItem_Value_Concentra	Y	ON	L.Number = Y.LCR_EQBLineItem_Number
			WHERE		L.Number >= 1  
			--
			ORDER BY	L.Number	ASC		
			--
			;	

			SET @RowCount = @@ROWCOUNT 
			IF @DEBUG = 1 BEGIN PRINT dbo.fcn_DebugInfo( ' rows: ' + convert(varchar(20),@RowCount) ) END ; 

		END TRY		
		BEGIN CATCH 
			
			SET @ErrorMessage = 'An error occurred while attempting to populate input/output result temporary table.' 
			GOTO ERROR	

		END CATCH
		
		--	Check if duplicate data and delete when duplicate

		IF EXISTS (SELECT * FROM TA.liquidity.LCR_EQBandConcentra_Daily WHERE EffectiveDate = @EffectiveDate)
		BEGIN
				DELETE TA.liquidity.LCR_EQBandConcentra_Daily WHERE EffectiveDate = @EffectiveDate
		END

		INSERT INTO TA.liquidity.LCR_EQBandConcentra_Daily
		(
		EffectiveDate,
		MonthEnd,
		LCR_EQBLineItem_Number,
		EQB_Value,
		Concentra_Value,
		LCR_EQBLineItem_Note,
		EQB_Value_Thousands,
		Concentra_Value_Thousands
		)
		SELECT		@EffectiveDate		as	EffectiveDate	
		,			@MonthEnd			as	MonthEnd		
		--		
		,			L.Number	as	LCR_EQBLineItem_Number
		,			X.[Value]	as	EQB_Value
		,			Y.[Value]	as	Concentra_Value					
		,			L.Note		as	LCR_EQBLineItem_Note
		,			coalesce(X.[Value],0.0000) / 1000.0000	as	EQB_Value_Thousands
		,			coalesce(Y.[Value],0.0000) / 1000.0000	as	Concentra_Value_Thousands 
		FROM		liquidity.LCR_EQBLineItem_Daily		L			
		LEFT  JOIN	#lcr_STAGING_LineItem_Value_EQB	X	ON	L.Number = X.LCR_EQBLineItem_Number 
		LEFT  JOIN  #lcr_STAGING_LineItem_Value_Concentra	Y	ON	L.Number = Y.LCR_EQBLineItem_Number
		WHERE		L.Number >= 1  
		--
		ORDER BY	L.Number	ASC		
		--
		;

	END 

	--
	--

	FINISH:		
	
	IF @DEBUG = 1 BEGIN PRINT dbo.fcn_DebugInfo( 'END ' + object_schema_name( @@PROCID ) + '.' + object_name( @@PROCID ) ) END ; 
	
	--

	DROP TABLE #lcr_EQB_DepositNoteMaturities 
	DROP TABLE #lcr_EQB_LiquidityPortfolio 
	DROP TABLE #lcr_Concentra_LiquidityPortfolio
	DROP TABLE #lcr_EQB_UndisbursedCommitments

	DROP TABLE #lcr_EQB_LargestNetCollateralFlow
	--
	DROP TABLE #lcr_STAGING_LineItem_Value_EQB 
	DROP TABLE #lcr_STAGING_LineItem_Value_Concentra 

	DROP TABLE #lcr_Concentra_Deposits
	DROP TABLE #lcr_EQB_Deposits
	DROP TABLE #lcr_EQB_Mortgage_Inflows
	DROP TABLE #lcr_EQB_Securitization_Cashflows
	DROP TABLE #lcr_Concentra_Mgt_Commitment
	DROP TABLE #lcr_Concentra_Mgt_Inflow
	DROP TABLE #lcr_Concentra_Derivative_Cashflow

	DROP TABLE #usp_RelationshipBalances_Output
	DROP TABLE #usp_RelationshipBalances_CustomerLevel_Output
	DROP TABLE #lcr_EQB_Securitization_Loan_Maturities
	DROP TABLE #lcr_Check_NULL_EQB
	DROP tABLE #lcr_Check_NULL_Concentra

	RETURN 1 ;
	--
	--
	
	ERROR:	
	
	IF @ErrorMessage IS NOT NULL 
	BEGIN 

		RAISERROR ( @ErrorMessage , 16 , 1 ) ; 

	END		

	IF len(@NULL_Message_EQB) > 36 
	BEGIN
																	-- 2025-01-20
		RAISERROR ( @NULL_Message_EQB, 16, 1)
	END

	IF len(@NULL_Message_Concentra) > 42
	BEGIN

		RAISERROR ( @NULL_Message_Concentra, 16, 1)
	END

	RETURN -1 ; 
	
--
--
--

/*

	--
	--	EXAMPLE for @Mode = 'TEMP' 
	--	
	
	IF OBJECT_ID('tempdb..#usp_Calculate_LCR_Output') IS NOT NULL DROP TABLE #usp_Calculate_LCR_Output
	CREATE TABLE #usp_Calculate_LCR_Output
	(
		ID							int				not null	identity(1,1)		primary key		clustered 
	--
	,	RunTimestamp				datetime		not null	
	--	
	,	EffectiveDate				date			not null 
	,	MonthEnd					bit				not null 
	--
	,	LCR_EQBLineItem_Number		int				not null	
	--
	,	[Value]						float			null 
	,	LCR_EQBLineItem_Note		varchar(100)	not null 
	--
	,	Value_Thousands				float			not null	
	--	
	)	
	;	
	
			EXEC	liquidity_exec.usp_Calculate_LCR	
						@EffectiveDate			=	null 
					,	@MonthEnd				=	0 
					--
					,	@Mode					=	'TEMP'			
					--
					,	@DEBUG					=	1		
					--			
			 ;	

		--
		--

		SELECT		X.*
		FROM		#usp_Calculate_LCR_Output	X	
		--	
		;	

		--
		--

*/	

END
