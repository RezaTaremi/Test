USE [Concentra]
GO

/****** Object:  View [TBSM].[vw_Deposits_Daily]    Script Date: 8/15/2025 2:12:09 PM ******/
SET ANSI_NULLS ON
GO

SET QUOTED_IDENTIFIER ON
GO









/*
drop view [TBSM].[vw_Deposits_Daily]
*/


ALTER VIEW [TBSM].[vw_Deposits_Daily]	  with SCHEMABINDING
AS	
/**************************************************************************************

	Displays Concentra deposit records. 

		
		Example:	


			SELECT		*	
			--	
			FROM		TBSM.vw_Deposits_Daily  X		
			--
			WHERE		X.AsOfDate = '2022-12-01'
			--	
			ORDER BY	X.AsOfDate				DESC	
			,			X.SourceTable			ASC		
			,			X.ProductType			DESC	
			--		
			;	


	Date		Who	Action	
	----------	---	----------------------------
	2022-11-30		Created initial version.	
	2022-12-23		Used Referral in Retail_Deposit (brokered deposits) as subproducttype
	2023-01-10		Changed "Non Redeemable" to "Non-Redeemable" where applicable
    2023-03-02  AWT Excluded NEO suspense account from commercial deposits.
	2023-03-14		Updated Product 'Indirect Long Term Annual'as non-redeemable.
	2023-05-19		Added [Province] field.
	2023-12-01		Added fields [Comp_Int_to_Date].
	2023-12-05		Changed the Term_Type names in Deposit_Retail_Nominee_Daily.
	2024-05-07		Separate Notice Deposit from All Deposits.
	2024-07-25		Marking other CU notice deposits.
	2024-09-05		Updated Neo and Retail Rate.
	2024-11-07		Added 'Notice Given' to Red_NonRed field.
    2025-06-12      Adjusting the table name for some CU deposits that are currently under Deposit_Commercial_Daily table
    2025-07-24      Removing the account from demand deposits and addint back to notice-atlantic term deposits
**************************************************************************************/	



	SELECT		A.FileDate
	,			CASE WHEN A.Product LIKE '%CU%' THEN 'CreditUnion_Deposit'  --2025-06-12
                ELSE 'Commercial_Client' END AS	SourceTable
	,			A.[As of]						AsOfDate
	,			'Non-Term'						DepositType
	,			A.[Account Number]				AccountNumber
	,			null							CIF_NO
	,			A.Product						ProductType
	,			A.[Product Type]				SubproductType
	,			A.Major							Major
	,			null							Red_NonRed
	,			A.[Current Balance]				Balance
	,			A.[Interest Rate]				InterestRate
	,			A.[Accrued Interest]			AccruedInterest
	,			0.00							Comp_Int_to_Date
	,			A.[Contract Date]				IssueDate
	,			null							MaturityDate
	,			null							Term
	,			null							Referral
	--- New line for Province
	,			LEFT(RIGHT(LTRIM(RTRIM(A.Address)),11),2)		Province
	--	
	FROM		TBSM.Deposit_Commercial_Daily		A
	WHERE		A.Major IN ('CK' , 'SAV')
        AND     A.[Lastname, Firstname] NOT LIKE 'NEO [CS]%' --Exclude NEO deposits suspense accounts that equal NEO source while leaving NEO T* that are NEO's own deposits with us..
        AND     A.[Account Number] != '833400146761'        -- 2025-07-24   notice atlantic from demand deposits

    --	
	--
	UNION ALL
	--
	--
	SELECT		A.FileDate
	,			'NEO_Deposit'					SourceTable
	,			A.Snapshot_Date					AsOfDate
	,			'Non-Term'						DepositType
	,			A.Deposit_Number				AccountNumber
	,			null							CIF_NO
	,			A.Product_Type					ProductType
	,			A.Deposit_Counterparty_Class	SubproductType
	,			null 							Major
	,			null							Red_NonRed
	,			A.Current_Principal_Balance		Balance
	,			A.Interest_Rate * 0.01			InterestRate				--2024-09-05 -devide by 100
	,			A.Accrued_Interest				AccruedInterest
	,			0.00							Comp_Int_to_Date
	,			A.Issue_Date					IssueDate
	,			null							MaturityDate
	,			null							Term
	,			null							Referral
	--- New line for Province
	,			null                    Province
	--
	--	
	FROM		TBSM.Deposit_NEO_Daily		A
	--	
	--
	UNION ALL
	--
	--
	SELECT		A.FileDate
	,			'Retail_Deposit'				SourceTable
	,			A.[As of]						AsOfDate
	,			'Non-Term'						DepositType
	,			A.[Account Number]				AccountNumber
	,			null							CIF_NO
	,			A.Product						ProductType
	,			A.Product						SubproductType
	,			A.Major							Major
	,			null							Red_NonRed
	,			A.[Current Balance]				Balance
	,			A.[Interest Rate]				InterestRate
	,			A.[Accrued Interest]			AccruedInterest
	,			0.00							Comp_Int_to_Date
	,			A.[Contract Date]				IssueDate
	,			null							MaturityDate
	,			null							Term
	,			null							Referral
	--- New line for Province
	,			null                    Province
	--
	--	
	FROM		TBSM.Deposit_Retail_Digital_Daily		A
	WHERE		A.Major IN ('CK' , 'SAV')
	--	
	--
	UNION ALL
	--
	--
	SELECT		A.FileDate
	,			'CreditUnion_Deposit'			SourceTable
	,			dateadd(day, -1, A.FileDate)	AsOfDate
	,			CASE WHEN  A.Account_No =  '830260092762' 
					 THEN  'Term'						-- 2024-05-07   Separate Notice Deposit from All Deposits
					 ELSE 'Non-Term'		
				END	
	,			A.Account_No					AccountNumber
	,			null							CIF_NO
	,			A.Product						ProductType
	,			A.Product						SubproductType
	,			null							Major
	,			CASE WHEN  A.Account_No =  '830260092762' 
					 THEN  'Notice - Atlantic'						--	2024-05-07	Separate Notice Deposit from All Deposits
					 WHEN A.Product like '%Notice%'					--	2024-07-25	Marking other notice deposits
					 THEN 'Notice Deposit'							--	2024-07-25	
					 ELSE null	
				END	 +  CASE WHEN A.Product like '%Notice Given%'		--	2024-11-07	Adding Notice Given
							THEN ' - Notice Given'
							ELSE ''
						END									Red_NonRed
	,			A.Balance						Balance
	,			A.Interest_Rate					InterestRate
	,			A.Accrued_Interest				AccruedInterest
	,			0.00							Comp_Int_to_Date
	,			A.Contract_Date					IssueDate
	,			null							MaturityDate
	,			null							Term
	,			null							Referral
	--- New line for Province
	,			A.Province							Province

	--
	--	
	FROM		TBSM.Deposit_Credit_Union_Daily		A
	WHERE		A.Product_Category IN ('Demand', 'New') AND A.Maturity_Date IS NULL --2024-05-06 added 'New' and added maturity date constraint
	--	
	--
	UNION ALL		--	Term below
	--
	--
	SELECT		A.FileDate
	,			CASE
                WHEN A.Product LIKE '%CU%' THEN 'CreditUnion_Deposit'  -- 2025-06-12
                ELSE 'Commercial_Client'		  END AS	SourceTable
	,			A.[As of]						AsOfDate
	,			'Term'							DepositType
	,			A.[Account Number]				AccountNumber
	,			null							CIF_NO
	,			A.Product						ProductType
	,			a.[Product Type]				Subproducttype
	,			A.Major							Major
	,			CASE WHEN  A.Product LIKE '%Notice%'
					 THEN  'Notice Deposit'									-- 2024-05-07   Separate Notice Deposit from All Deposits
                     WHEN A.[Account Number] = '833400146761'               -- 2025-07-24   Include the account as Notice-Atlantic
                     THEN 'Notice - Atlantic'
					 WHEN A.Product LIKE '%NR%'						 
					 OR   A.Product LIKE '%Non Red%'
					 OR	  A.Product = 'Indirect Long Term Annual'		--	2023-03-14	These are non-redeemable
					 THEN 'Non-Redeemable'
					 ELSE 'Redeemable'
				END	 +  CASE WHEN A.Product like '%Notice Given%'		--	2024-11-07	Adding Notice Given
							THEN ' - Notice Given'
							ELSE ''
						END							Red_NonRed
	,			A.[Current Balance]				Balance
	,			A.[Interest Rate]				InterestRate
	,			A.[Accrued Interest]			AccruedInterest
	,			0.00							Comp_Int_to_Date
	,			A.[Contract Date]				IssueDate
	,			A.[Maturity Date]				MaturityDate
	,			datediff(month,A.[Contract Date], A.[Maturity Date])	Term
	--- New line for Province
	,			null							Referral
	,			LEFT(RIGHT(LTRIM(RTRIM(A.Address)),11),2)		Province

	--	
	FROM		TBSM.Deposit_Commercial_Daily		A
	WHERE		A.Major IN ('TD') OR A.[Account Number] = '833400146761'  --2025-07-24 Include the account as Notice-Atlantic
	--	
	--
	UNION ALL
	--
	--
	SELECT		A.FileDate
	,			'Retail_Deposit'				SourceTable
	,			dateadd(day, -1, A.FileDate)	AsOfDate
	,			CASE	--2023-12-05
					WHEN A.Term_Type = 'Cashable' THEN 'Term'
					WHEN A.Term_Type = 'Fixed' THEN 'Term'
					WHEN A.Term_Type = 'Variable' THEN 'Demand'
					ELSE A.Term_Type
				END as DepositType
	,			A.Plan_Number +'_'+ A.Instrument_No					AccountNumber
	,			A.CIF							CIF_NO
	,			A.Product						ProductType
	,			A.Referral						Subproducttype		--
	,			null							Major
	,			CASE --2023-12-05
					WHEN A.Term_Type = 'Variable' THEN NULL
					ELSE A.Red_Non
				END as Red_NonRed
	,			A.Principal						Balance
	,			A.Rate * 0.01					InterestRate			--2024-09-05 -devide by 100
	,			A.Accrd_Int						AccruedInterest
	,			A.Cmp_Int_to_Date				Comp_Int_to_Date
	,			A.Issue_Date					IssueDate
	,			A.Maturity						MaturityDate
	,			A.Term							Term
	--- New line for Province
	,			A.Referral						Referral
	,			null							Province

	--	
	FROM		TBSM.Deposit_Retail_Nominee_Daily		A
	--	
	--
	UNION ALL
	--
	--
	SELECT		A.FileDate
	,			'Retail_Account'				SourceTable
	,			A.[As of]						AsOfDate
	,			'Term'							DepositType
	,			A.[Account Number]				AccountNumber
	,			null							CIF_NO
	,			A.Product						ProductType
	,			null							Subproducttype
	,			A.Major							Major
	,			CASE WHEN A.Product LIKE '%NR'
					 THEN 'Non-Redeemable'
					 ELSE 'Redeemable'
				END								Red_NonRed
	,			A.[Current Balance]				Balance
	,			A.[Interest Rate]				InterestRate
	,			A.[Accrued Interest]			AccruedInterest
	,			0.00							Comp_Int_to_Date
	,			A.[Contract Date]				IssueDate
	,			A.[Maturity Date]				MaturityDate
	,			datediff(month,A.[Contract Date], A.[Maturity Date])	Term
	,			null					Referral
	--- New line for Province
	,			null                    Province

	--	
	FROM		TBSM.Deposit_Retail_Digital_Daily		A
	WHERE		A.Major IN ('TD')
	--	
	--
	UNION ALL
	--
	--
	SELECT		A.FileDate
	,			'CreditUnion_Deposit'			SourceTable
	,			dateadd(day, -1, A.FileDate)	AsOfDate
	,			'Term'							DepositType
	,			A.Account_No					AccountNumber
	,			null							CIF_NO
	,			A.Product						ProductType
	,			null							Subproducttype
	,			null							Major
	,			case when  A.Product_Category = 'Evergreen'
					 then 'Notice Deposit'						--	2024-05-07   Separate Notice Deposit from All Deposits
					 WHEN A.Product like '%Notice%'					--	2024-07-25	Marking other notice deposits
					 THEN 'Notice Deposit'							--	2024-07-25	
					 when A.Product_Category ='Non Redeemable' 
					 then 'Non-Redeemable'
				when A.Product_Category ='Redeemable'	
				
				then 'Redeemable'
				else 'Demand Deposit'
					end  +  CASE WHEN A.Product like '%Notice Given%'
								THEN ' - Notice Given'				--	2024-11-07	Adding Notice Given
								ELSE ''
							END	as Red_NonRed
	,			A.Balance						Balance
	,			A.Interest_Rate					InterestRate
	,			A.Accrued_Interest				AccruedInterest
	,			0.00							Comp_Int_to_Date
	,			A.Contract_Date					IssueDate
	,			A.Maturity_Date					MaturityDate
	,			datediff(month,A.Contract_Date, A.Maturity_Date)	Term
	,			null							Referral
	--- New line for Province
	,			A.Province						Province

	--	
	FROM		TBSM.Deposit_Credit_Union_Daily		A
	WHERE		A.Product_Category IN ('Non Redeemable' , 'Redeemable', 'Evergreen', 'New') AND A.Maturity_Date IS NOT NULL  --2024-05-06 added 'New' and added maturity date constraint
	--
	;	
	

GO


