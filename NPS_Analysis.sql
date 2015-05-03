-- Primary survey responses tables, created from IAC fed data 
drop table nps_survey_responses;
create table NPS_Survey_Responses as
select answer_3 as company_id, answer_2 as user_id, createdts, date(createdts) as survey_date, round(cast(answer_0 as numeric), 0) as NP_raw, 
case 
   when cast(answer_0 as numeric) <=  6 then 'Detractor'
   when cast(answer_0 as numeric) >=7 and cast(answer_0 as numeric) <=8 then 'Passive'   
   when cast(answer_0 as numeric) >=  9 then 'Promoter'
 end as NP_Segment,
 case 
   when cast(answer_0 as numeric) <=  6 then -1
   when cast(answer_0 as numeric) >=7 and cast(answer_0 as numeric) <=8 then 0  
   when cast(answer_0 as numeric) >=  9 then 1
 end as NP_Score,
 answer_1 as np_voice
from usg_sbg..survey_responses 
where surveyid = 'crq2pcnh' and traffictype = 'live' and answer_3 <> '' and answer_3 <> 'company_id'
group by 1,2,3,4,5,6,7,8; --12231 --Group by removes dupes which have different response IDs but are otherwise identical due to preload error at the CTO level
								  --THIS IS NOT CURRENTLY DEDUPING DUE TO CREATEDTS, FINAL TABLE MUST BE PRUNED OF DUPES

-- Join to Infrastructure Tables
-- UED_QBO_WS.MCHO1.QLIKVIEW_US_TOTAL_SUBS
drop table nps_intermediate;
create table NPS_intermediate as
select distinct a.company_id, A.survey_date, a.createdts, current_qbo_product, subscriber_flag, web_retail_flag, 
importer_flag, B.simple_trial_flag, B.fy16_channel, B.fy16_channel_agg, 
 case when region_id in (1,2,3,4,5,80,105,38) then region_id else 1000 end as region_id,
 case when payments_signup_date is not null and payments_cancel_date is null  then 1 else 0 end as payment_flag,
 case when payroll_attach_date is not null and payroll_cancel_date  is null  then 1 else 0 end as payroll_flag,
 case when CANCEL_DATE IS NOT NULL                                           then 1 else 0 end as cancel_flag,
 case when product_detailed <> 'Non-Promo'                                   then 1 else 0 end as promo_flag,
 case when ipp_appsattached is not null                                      then 1 else 0 end as ipp_flag,
 case 
   when mobile_recent_login_date is null then 'No Use'
   when mobile_recent_login_date > current_date - 30 then 'Current User' 
   else 'Past User'
  end as Mobile_Flag,
 case when extract(day from nvl(cancel_date, current_date) - first_charge_date) < 91   then 1 else 0 end as new_user_flag,-- young sub / change to days / vet with june
 --round(extract(day from nvl(cancel_date, current_date) - first_charge_date)/30.4167,0) as months_in_qbo,
 case
   when extract(day from nvl(cancel_date, current_date) - first_charge_date) < 91 then '3 Months or Less' 
   when extract(day from nvl(cancel_date, current_date) - first_charge_date) > 365 then '12 Months or More'
   else '4 - 12 Months'
   end as company_tenure,
 B.accountants_flag, B.accountant_attached_flag, B.payroll_bundle_flag, 
 case
   when neo_enabled = 1 and harmony_migration_date IS null then B.industry_type  -- Check with June
   else 'Unknown'
 end as industry_type,
 B.combined_importer_flag,
 np_segment, np_score, num_current_employees, NP_raw
 from usg_sbg_ws..nps_survey_responses a
 INNER join UED_QBO_WS.MCHO1.QLIKVIEW_US_TOTAL_SUBS B
 on a.company_id = b.company_id
 where lower(master_email) not like '@intuit'; --LEFT = 12189, INNER = 11875
 
 
 -- This will be replaced with PAP as soon as I get to it, prior to May 4
 select region_id, count(*) from nps_intermediate group by 1;
 -- Simba / Maya info, to be replaced by Primary Access Point
 -- UED_QBO_WS..abattan_ftu_mobile_simba_maya_attach
 drop table nps_intermediate_simba;
 create table nps_intermediate_simba as
 select a.*, 
 case when b.simba_flag = 1 then 1 else 0 end as simba_flag, 
 case when b.maya_flag = 1  then 1 else 0 end as maya_flag
 from nps_intermediate a
 left join (select company_id,
 				case when first_simba_use_date is null then 0 else 1 end as simba_flag,
                case when first_maya_use_date  is null then 0 else 1 end as maya_flag
				from UED_QBO_WS..abattan_ftu_mobile_simba_maya_attach) b
 on a.company_id = b.company_id;
 
-- Aggregate Industries 
-- UED_QBO_WS.HLERESNICK.HL_NAICS_COMPLETE
drop table nps_intermediate_industry; -- vet with June
create table nps_intermediate_industry as
select distinct a.*, 
case
  when naics_2_desc is not null then naics_2_desc
  when industry_type = 'Non-Profit' then 'Non-Profit'
  else 'Other' --   < 1%
end as industry_group
from nps_intermediate_simba a
left join UED_QBO_WS.HLERESNICK.HL_NAICS_COMPLETE b
on a.industry_type = b.naics_desc;

-- Add active / passive cancel logic
-- UED_QBO_DWH..RPTCANCELLEDCOMPANIES_1 
drop table nps_intermediate_cancel;
create table nps_intermediate_cancel as
select a.*,
case 
	when cancel_flag = 1 and USER_CANCELED  =  1 then 'Active Cancel' 
	when cancel_flag = 1 and (user_canceled IS NULL) then 'Passive Cancel'
	else 'Current Subscriber' 
end as cancel_type
FROM  usg_sbg_ws..nps_intermediate_industry A
left JOIN  (SELECT UNIQUE COMPANY_ID, USER_CANCELED, COMMENTS FROM UED_QBO_DWH..RPTCANCELLEDCOMPANIES_1 ) C 
ON A.COMPANY_ID = C.COMPANY_ID;
 
-- Find Payments Active Status
-- ued_qbo_ws..BSMITH_QBO_M2MFLAT_FULL / UED_QBO_WS..BSMITH_PAYMENTS_MERCHANT_BASEUP
drop table nps_intermediate_payments;
create table nps_intermediate_payments as
select a.*,
case 
  when a.payment_flag = 0 then 'No Payments'
  when a.payment_flag = 1 and b.active_last28 = 0 then 'Inactive User'
  when a.payment_flag = 1 and b.active_last28 = 1 then 'Active User'
  else 'No Payments'
end as Payments_active_flag
from
(select c.*, merchantID
from usg_sbg_ws..NPS_INTERMEDIATE_CANCEL c
left join ued_qbo_ws..BSMITH_QBO_M2MFLAT_FULL d 
on c.company_id = d.company_id) a
left join UED_QBO_WS.BSMITH22.BSMITH_PAYMENTS_MERCHANT_BASEUP b 
on a.merchantID = b.merchantid; -- THE RESULTS OF THIS TABLE ARE NON-CARDINAL. THERE ARE MULTIPLE MERCHANT IDS PER COMPANY ID 
 								-- I also note discrepacies, Needs to be double checked

 
-- Resolve multiple Merchant Ids to most active state, by ranking over status (cleverly alphabetically arranged)
drop table nps_intermediate_cardinal;
create table nps_intermediate_cardinal as
select DISTINCT COMPANY_ID, SURVEY_DATE, createdts, CURRENT_QBO_PRODUCT, SUBSCRIBER_FLAG, WEB_RETAIL_FLAG, IMPORTER_FLAG, SIMPLE_TRIAL_FLAG, FY15_CHANNEL, FY15_CHANNEL_AGG, REGION_ID, PAYMENT_FLAG, PAYROLL_FLAG, CANCEL_TYPE, IPP_FLAG, NEW_USER_FLAG, COMPANY_TENURE, ACCOUNTANTS_FLAG, ACCOUNTANT_ATTACHED_FLAG, INDUSTRY_GROUP, COMBINED_IMPORTER_FLAG, NP_SEGMENT, NUM_CURRENT_EMPLOYEES, NP_RAW, NP_SCORE, SIMBA_FLAG, MAYA_FLAG, PAYMENTS_ACTIVE_FLAG, mobile_flag 
from (select *, 
rank() over(partition by company_id order by payments_active_flag) as payments_rank --ranks strings by first letters, names sort alphabetically the way I want 
from nps_intermediate_payments) a
where payments_rank = 1;	 
 
 --Penultimate Table for insert into Final Table
 -- UED_QBO_WS.MCHO1.RPTDAILYUSAGE
 drop table nps_tableau_data_merge;
 create table usg_sbg_ws..NPS_Tableau_data_merge as
 select front.company_id,
 		front.current_qbo_product, --2
 		front.subscriber_flag, 
		front.importer_flag, 
		front.simple_trial_flag, 
		front.fy16_channel, --6
		front.fy16_channel_agg, 
		front.region_id,
 		front.payments_active_flag, 	   
		front.payroll_flag,    
		front.cancel_type as cancel_flag,       
		front.new_user_flag,  
		front.accountants_flag,
		front.accountant_attached_flag, 
		front.industry_group as industry_type, 
		front.combined_importer_flag, 
		front.num_current_employees, 
		front.web_retail_flag, 
		front.ipp_flag,
		front.simba_flag,
		front.maya_flag,
		front.mobile_flag,
		front.company_tenure,
		front.np_raw,
		front.np_segment, 
		front.np_score as NP_multiplier,
		/*firm.load_count, 
		firm.login_count, 
		firm.employee_count, 
		firm.customer_count,
		firm.user_count, 
		firm.vendor_count,*/
		survey_date,
		createdts,
		1 as company_count,  --28
		np_score  --29
 from usg_sbg_ws..nps_intermediate_cardinal front; 
 /*  -- O FIRMOGRAPHICS
 select * from nps_tableau_data limit 100;
 left join (select company_id, count(distinct load_date) as load_count, sum(num_logins) as login_count, 
 																		 sum(num_employees) as employee_count, 
																		 sum(num_customers) as customer_count, 
																		 sum(num_vendors) as vendor_count, 
																		 sum(num_users) as user_count
			from UED_QBO_WS.MCHO1.RPTDAILYUSAGE -- Use customers_1 vendors table does not show deletes!!!!!!
			where load_date > current_date - 92 and load_date < current_date - 2
			group by 1) firm
 on front.company_id = firm.company_id;*/
 
 
-- Final Table 
insert into nps_tableau_data 
(select * from nps_tableau_data_merge 
where createdts > (select max(createdts) from nps_tableau_data));

drop table nps_tableau_backup;
create table nps_tableau_backup
as select * from nps_tableau_data;
drop table nps_tableau_data;

create table nps_tableau_data as
select
		company_id,
 		current_qbo_product, --2
 		subscriber_flag, 
		importer_flag, 
		simple_trial_flag, 
		fy15_channel, --6
		fy15_channel_agg, 
		region_id,
 		payments_active_flag, 	   
		payroll_flag,    --10
		cancel_flag,       
		new_user_flag,  
		accountants_flag,
		accountant_attached_flag, 
		industry_type, 
		combined_importer_flag, 
		num_current_employees, 
		web_retail_flag, 
		ipp_flag,
		simba_flag, --20
		maya_flag,
		mobile_flag,
		company_tenure,
		np_raw,
		np_segment, 
		NP_multiplier,
		survey_date,
		company_count,  --28
		np_score  --29
from nps_tableau_backup
group by 1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,16,17,18,19,20,21,22,23,24,25,26,27,28,29;

select Count(*) from nps_tableau_data; 
--Begin Text Analysis 
 
-- Break up verbatims by into sentences, per Clarabridge		
drop table nps_verbatim_substring;

create table NPS_verbatim_substring as
 select Company_Id,rtrim(ltrim(mySubstring)) as NPS_verbatim_label, lower(rtrim(ltrim(mySubstring))) as NPS_verbatim_split  from (
 select 
 a.*, 
 m.i,
 case 
   when i - 1 = 0 then 1
   else instr(lower_voice,'.',1,i-1)
 end as myPosition, 
 instr(lower_voice,'.',1,i) myPosition2, 
 case 
   when myposition = 1 then substr(np_voice,myPosition,myPosition2) 
   else substr(np_voice,myPosition + 1 ,myPosition2 - myPosition)
 end as mySubstring
 from (select company_id, np_voice,
   lower(np_voice) as lower_voice, 
   length(np_voice) - length(translate(np_voice,'.','')) as numberReasons
   from usg_sbg_ws..nps_survey_responses) a,
   ued_qbo_ws..master_thousand m
WHERE
                m.i<=numberReasons
				order by 1, 4) f
				where length(mySubstring) > 10;
				
				
select length(np_voice), count(*) from NPS_survey_responses group by 1;
drop table nps_tableau_verbatims;
create table NPS_tableau_verbatims as
SELECT * FROM (
SELECT *, CASE 
 WHEN NPS_VERBATIM_SPLIT LIKE '%accessible%' OR NPS_VERBATIM_SPLIT LIKE '%can not find%' OR NPS_VERBATIM_SPLIT LIKE '%clear%' OR NPS_VERBATIM_SPLIT LIKE '%complicated%' OR NPS_VERBATIM_SPLIT LIKE '%difficult to follow%' OR NPS_VERBATIM_SPLIT LIKE '%difficult to use%' OR NPS_VERBATIM_SPLIT LIKE '%hard to find%' OR NPS_VERBATIM_SPLIT LIKE '%hassle%' OR NPS_VERBATIM_SPLIT LIKE '%instructions%' OR NPS_VERBATIM_SPLIT LIKE '%intuitive%' OR NPS_VERBATIM_SPLIT LIKE '%irritating%' OR NPS_VERBATIM_SPLIT LIKE '%navigate%' OR NPS_VERBATIM_SPLIT LIKE '%no problem%' OR NPS_VERBATIM_SPLIT LIKE '%onerous%' OR NPS_VERBATIM_SPLIT LIKE '%problematic%' OR NPS_VERBATIM_SPLIT LIKE '%quality%' OR NPS_VERBATIM_SPLIT LIKE '%straight forward%' OR NPS_VERBATIM_SPLIT LIKE '%trouble%' OR NPS_VERBATIM_SPLIT LIKE '%troublesome%' OR NPS_VERBATIM_SPLIT LIKE '%eas% %' OR NPS_VERBATIM_SPLIT LIKE '%confus% %'  AND (NPS_VERBATIM_SPLIT NOT LIKE '%at ease%' AND NPS_VERBATIM_SPLIT NOT LIKE '%contact%' AND NPS_VERBATIM_SPLIT NOT LIKE '%cs%' AND NPS_VERBATIM_SPLIT NOT LIKE '%csr%' AND NPS_VERBATIM_SPLIT NOT LIKE '%customer service%' AND NPS_VERBATIM_SPLIT NOT LIKE '%dude%' AND NPS_VERBATIM_SPLIT NOT LIKE '%east%' AND NPS_VERBATIM_SPLIT NOT LIKE '%english%' AND NPS_VERBATIM_SPLIT NOT LIKE '%everyone%' AND NPS_VERBATIM_SPLIT NOT LIKE '%friendly%' AND NPS_VERBATIM_SPLIT NOT LIKE '%gal%' AND NPS_VERBATIM_SPLIT NOT LIKE '%grammar%' AND NPS_VERBATIM_SPLIT NOT LIKE '%he%' AND NPS_VERBATIM_SPLIT NOT LIKE '%her%' AND NPS_VERBATIM_SPLIT NOT LIKE '%him%' AND NPS_VERBATIM_SPLIT NOT LIKE '%his%' AND NPS_VERBATIM_SPLIT NOT LIKE '%lady%' AND NPS_VERBATIM_SPLIT NOT LIKE '%man%' AND NPS_VERBATIM_SPLIT NOT LIKE '%people%' AND NPS_VERBATIM_SPLIT NOT LIKE '%phillipines%' AND NPS_VERBATIM_SPLIT NOT LIKE '%phone%' AND NPS_VERBATIM_SPLIT NOT LIKE '%polite%' AND NPS_VERBATIM_SPLIT NOT LIKE '%prompt%' AND NPS_VERBATIM_SPLIT NOT LIKE '%rude%' AND NPS_VERBATIM_SPLIT NOT LIKE '%service%' AND NPS_VERBATIM_SPLIT NOT LIKE '%she%' AND NPS_VERBATIM_SPLIT NOT LIKE '%someone%' AND NPS_VERBATIM_SPLIT NOT LIKE '%speak up%' AND NPS_VERBATIM_SPLIT NOT LIKE '%support%' AND NPS_VERBATIM_SPLIT NOT LIKE '%talk louder%' AND NPS_VERBATIM_SPLIT NOT LIKE '%tech%' AND NPS_VERBATIM_SPLIT NOT LIKE '%technician%' AND NPS_VERBATIM_SPLIT NOT LIKE '%the response%' AND NPS_VERBATIM_SPLIT NOT LIKE '%their%' AND NPS_VERBATIM_SPLIT NOT LIKE '%they%' AND NPS_VERBATIM_SPLIT NOT LIKE '%whisper%' AND NPS_VERBATIM_SPLIT NOT LIKE '%woman% %' AND NPS_VERBATIM_SPLIT NOT LIKE '%accent% %' AND NPS_VERBATIM_SPLIT NOT LIKE '%agent% %' AND NPS_VERBATIM_SPLIT NOT LIKE '%america% %' AND NPS_VERBATIM_SPLIT NOT LIKE '%assistan% %' AND NPS_VERBATIM_SPLIT NOT LIKE '%gentleman% %' AND NPS_VERBATIM_SPLIT NOT LIKE '%india% %' AND NPS_VERBATIM_SPLIT NOT LIKE '%individual% %' AND NPS_VERBATIM_SPLIT NOT LIKE '%language% %' AND NPS_VERBATIM_SPLIT NOT LIKE '%outsourc% %' AND NPS_VERBATIM_SPLIT NOT LIKE '%communicat% %' AND NPS_VERBATIM_SPLIT NOT LIKE '%foreign% %' AND NPS_VERBATIM_SPLIT NOT LIKE '%person% %' AND NPS_VERBATIM_SPLIT NOT LIKE '%guy% %' AND NPS_VERBATIM_SPLIT NOT LIKE '%rep% %' AND NPS_VERBATIM_SPLIT NOT LIKE '%spell% %' ) THEN 'Ease of Use'
 END AS CAT 
 FROM USG_SBG_WS..NPS_VERBATIM_SUBSTRING
 UNION 
 SELECT *, CASE 
 WHEN NPS_VERBATIM_SPLIT LIKE '%qbwebpatch%' OR NPS_VERBATIM_SPLIT LIKE '%reinstall%' OR NPS_VERBATIM_SPLIT LIKE '%reinstalled%' OR NPS_VERBATIM_SPLIT LIKE '%reinstalling%' OR NPS_VERBATIM_SPLIT LIKE '%reinstalls%' OR NPS_VERBATIM_SPLIT LIKE '%release%' OR NPS_VERBATIM_SPLIT LIKE '%system requirements%' OR NPS_VERBATIM_SPLIT LIKE '%update%' OR NPS_VERBATIM_SPLIT LIKE '%update-%' OR NPS_VERBATIM_SPLIT LIKE '%-.net%' OR NPS_VERBATIM_SPLIT LIKE '%.net%' OR NPS_VERBATIM_SPLIT LIKE '%.netframework%' OR NPS_VERBATIM_SPLIT LIKE '%updated%' OR NPS_VERBATIM_SPLIT LIKE '%updated-%' OR NPS_VERBATIM_SPLIT LIKE '%updates%' OR NPS_VERBATIM_SPLIT LIKE '%updates-%' OR NPS_VERBATIM_SPLIT LIKE '%updating%' OR NPS_VERBATIM_SPLIT LIKE '%webpatch%' OR NPS_VERBATIM_SPLIT LIKE '%install%' OR NPS_VERBATIM_SPLIT LIKE '%installation%' OR NPS_VERBATIM_SPLIT LIKE '%installed%' OR NPS_VERBATIM_SPLIT LIKE '%installer%' OR NPS_VERBATIM_SPLIT LIKE '%installing%' OR NPS_VERBATIM_SPLIT LIKE '%installs%' OR NPS_VERBATIM_SPLIT LIKE '%load%' OR NPS_VERBATIM_SPLIT LIKE '%loaded%' OR NPS_VERBATIM_SPLIT LIKE '%loading%' OR NPS_VERBATIM_SPLIT LIKE '%loads%' OR NPS_VERBATIM_SPLIT LIKE '%manual patch%' OR NPS_VERBATIM_SPLIT LIKE '%patch%'  THEN 'Install'
 END AS CAT 
 FROM USG_SBG_WS..NPS_VERBATIM_SUBSTRING
 UNION 
 SELECT *, CASE 
 WHEN NPS_VERBATIM_SPLIT LIKE '%download%' OR NPS_VERBATIM_SPLIT LIKE '%download-%' OR NPS_VERBATIM_SPLIT LIKE '%downloaded%' OR NPS_VERBATIM_SPLIT LIKE '%downloaded-%' OR NPS_VERBATIM_SPLIT LIKE '%downloading%' OR NPS_VERBATIM_SPLIT LIKE '%downloads%'  THEN 'Download'
 END AS CAT 
 FROM USG_SBG_WS..NPS_VERBATIM_SUBSTRING
 UNION 
 SELECT *, CASE 
 WHEN NPS_VERBATIM_SPLIT LIKE '%conversion%' OR NPS_VERBATIM_SPLIT LIKE '%conversion-%' OR NPS_VERBATIM_SPLIT LIKE '%conversions%' OR NPS_VERBATIM_SPLIT LIKE '%convert%' OR NPS_VERBATIM_SPLIT LIKE '%converted%' OR NPS_VERBATIM_SPLIT LIKE '%converter%' OR NPS_VERBATIM_SPLIT LIKE '%converter-%' OR NPS_VERBATIM_SPLIT LIKE '%converters%' OR NPS_VERBATIM_SPLIT LIKE '%converting%' OR NPS_VERBATIM_SPLIT LIKE '%convertion%' OR NPS_VERBATIM_SPLIT LIKE '%update%' OR NPS_VERBATIM_SPLIT LIKE '%updated%' OR NPS_VERBATIM_SPLIT LIKE '%updating%' OR NPS_VERBATIM_SPLIT LIKE '%upgrade%' OR NPS_VERBATIM_SPLIT LIKE '%upgraded%' OR NPS_VERBATIM_SPLIT LIKE '%upgrading%'  THEN 'Upgrade / Convert'
 END AS CAT 
 FROM USG_SBG_WS..NPS_VERBATIM_SUBSTRING
 UNION 
 SELECT *, CASE 
 WHEN NPS_VERBATIM_SPLIT LIKE '%configure%' OR NPS_VERBATIM_SPLIT LIKE '%configured%' OR NPS_VERBATIM_SPLIT LIKE '%configures%' OR NPS_VERBATIM_SPLIT LIKE '%configuring%' OR NPS_VERBATIM_SPLIT LIKE '%set up%' OR NPS_VERBATIM_SPLIT LIKE '%sets up%' OR NPS_VERBATIM_SPLIT LIKE '%setting up%' OR NPS_VERBATIM_SPLIT LIKE '%setup%'  THEN 'Setup'
 END AS CAT 
 FROM USG_SBG_WS..NPS_VERBATIM_SUBSTRING
 UNION 
 SELECT *, CASE 
 WHEN NPS_VERBATIM_SPLIT LIKE '%degraded%' OR NPS_VERBATIM_SPLIT LIKE '%degrades%' OR NPS_VERBATIM_SPLIT LIKE '%degrading%' OR NPS_VERBATIM_SPLIT LIKE '%faster%' OR NPS_VERBATIM_SPLIT LIKE '%freeze%' OR NPS_VERBATIM_SPLIT LIKE '%freezes%' OR NPS_VERBATIM_SPLIT LIKE '%freezing%' OR NPS_VERBATIM_SPLIT LIKE '%froze%' OR NPS_VERBATIM_SPLIT LIKE '%frozen%' OR NPS_VERBATIM_SPLIT LIKE '%hang%' OR NPS_VERBATIM_SPLIT LIKE '%hanging%' OR NPS_VERBATIM_SPLIT LIKE '%hangs%' OR NPS_VERBATIM_SPLIT LIKE '%hung%' OR NPS_VERBATIM_SPLIT LIKE '%lock up%' OR NPS_VERBATIM_SPLIT LIKE '%locks%' OR NPS_VERBATIM_SPLIT LIKE '%locks up%' OR NPS_VERBATIM_SPLIT LIKE '%not as fast%' OR NPS_VERBATIM_SPLIT LIKE '%performance%' OR NPS_VERBATIM_SPLIT LIKE '%seconds%' OR NPS_VERBATIM_SPLIT LIKE '%slow%' OR NPS_VERBATIM_SPLIT LIKE '%slower%' OR NPS_VERBATIM_SPLIT LIKE '%slowly%' OR NPS_VERBATIM_SPLIT LIKE '%slows%'  AND (NPS_VERBATIM_SPLIT NOT LIKE '%accent%' AND NPS_VERBATIM_SPLIT NOT LIKE '%english%' AND NPS_VERBATIM_SPLIT NOT LIKE '%foreign%' AND NPS_VERBATIM_SPLIT NOT LIKE '%hang up%' AND NPS_VERBATIM_SPLIT NOT LIKE '%hanging up%' AND NPS_VERBATIM_SPLIT NOT LIKE '%hung up%' AND NPS_VERBATIM_SPLIT NOT LIKE '%indian%' AND NPS_VERBATIM_SPLIT NOT LIKE '%left me hanging%' AND NPS_VERBATIM_SPLIT NOT LIKE '%left us hanging%' AND NPS_VERBATIM_SPLIT NOT LIKE '%offshore%' AND NPS_VERBATIM_SPLIT NOT LIKE '%over seas%' AND NPS_VERBATIM_SPLIT NOT LIKE '%repeat%' AND NPS_VERBATIM_SPLIT NOT LIKE '%speak% %' AND NPS_VERBATIM_SPLIT NOT LIKE '%understand%' ) THEN 'Performance'
 END AS CAT 
 FROM USG_SBG_WS..NPS_VERBATIM_SUBSTRING
 UNION 
 SELECT *, CASE 
 WHEN NPS_VERBATIM_SPLIT LIKE '%account info%' OR NPS_VERBATIM_SPLIT LIKE '%account information%' OR NPS_VERBATIM_SPLIT LIKE '%acct info%' OR NPS_VERBATIM_SPLIT LIKE '%activate%' OR NPS_VERBATIM_SPLIT LIKE '%activating%' OR NPS_VERBATIM_SPLIT LIKE '%cancel%' OR NPS_VERBATIM_SPLIT LIKE '%cancel-%' OR NPS_VERBATIM_SPLIT LIKE '%canceled%' OR NPS_VERBATIM_SPLIT LIKE '%canceled-%' OR NPS_VERBATIM_SPLIT LIKE '%canceling%' OR NPS_VERBATIM_SPLIT LIKE '%cancell%' OR NPS_VERBATIM_SPLIT LIKE '%cancelled%' OR NPS_VERBATIM_SPLIT LIKE '%cancelling%' OR NPS_VERBATIM_SPLIT LIKE '%cancels%' OR NPS_VERBATIM_SPLIT LIKE '%charg% %' OR NPS_VERBATIM_SPLIT LIKE '%lic%' OR NPS_VERBATIM_SPLIT LIKE '%licence%' OR NPS_VERBATIM_SPLIT LIKE '%licencenumber%' OR NPS_VERBATIM_SPLIT LIKE '%license%' OR NPS_VERBATIM_SPLIT LIKE '%licenses%' OR NPS_VERBATIM_SPLIT LIKE '%order status%' OR NPS_VERBATIM_SPLIT LIKE '%prod num%' OR NPS_VERBATIM_SPLIT LIKE '%prod numb%' OR NPS_VERBATIM_SPLIT LIKE '%product num%' OR NPS_VERBATIM_SPLIT LIKE '%product numb%' OR NPS_VERBATIM_SPLIT LIKE '%product number%' OR NPS_VERBATIM_SPLIT LIKE '%productnumber%' OR NPS_VERBATIM_SPLIT LIKE '%refund%' OR NPS_VERBATIM_SPLIT LIKE '%refund-%' OR NPS_VERBATIM_SPLIT LIKE '%refunded%' OR NPS_VERBATIM_SPLIT LIKE '%refunding%' OR NPS_VERBATIM_SPLIT LIKE '%refunds%' OR NPS_VERBATIM_SPLIT LIKE '%renew%' OR NPS_VERBATIM_SPLIT LIKE '%renewal%' OR NPS_VERBATIM_SPLIT LIKE '%return%' OR NPS_VERBATIM_SPLIT LIKE '%returned%' OR NPS_VERBATIM_SPLIT LIKE '%returning%' OR NPS_VERBATIM_SPLIT LIKE '%returns bill% %'  AND (NPS_VERBATIM_SPLIT NOT LIKE '%bill due%' AND NPS_VERBATIM_SPLIT NOT LIKE '%unpaid bills%' AND NPS_VERBATIM_SPLIT NOT LIKE '%call% %' AND NPS_VERBATIM_SPLIT NOT LIKE '%statement charge% %' ) THEN 'Customer Service'
 END AS CAT 
 FROM USG_SBG_WS..NPS_VERBATIM_SUBSTRING
 UNION 
 SELECT *, CASE 
 WHEN NPS_VERBATIM_SPLIT LIKE '%disc%' OR NPS_VERBATIM_SPLIT LIKE '%product%' OR NPS_VERBATIM_SPLIT LIKE '%program%' OR NPS_VERBATIM_SPLIT LIKE '%software%'  AND (NPS_VERBATIM_SPLIT LIKE '%basic%' OR NPS_VERBATIM_SPLIT LIKE '%enterprise%' OR NPS_VERBATIM_SPLIT LIKE '%premier%' OR NPS_VERBATIM_SPLIT LIKE '%pro%' OR NPS_VERBATIM_SPLIT LIKE '%qb%' OR NPS_VERBATIM_SPLIT LIKE '%qbooks%' OR NPS_VERBATIM_SPLIT LIKE '%quickbooks%' OR NPS_VERBATIM_SPLIT LIKE '%simple start%' OR NPS_VERBATIM_SPLIT LIKE '%quick books%' ) THEN 'Product'
 END AS CAT 
 FROM USG_SBG_WS..NPS_VERBATIM_SUBSTRING
 UNION 
 SELECT *, CASE 
 WHEN NPS_VERBATIM_SPLIT LIKE '%access%' OR NPS_VERBATIM_SPLIT LIKE '%accessing%' OR NPS_VERBATIM_SPLIT LIKE '%back-up%' OR NPS_VERBATIM_SPLIT LIKE '%back-ups%' OR NPS_VERBATIM_SPLIT LIKE '%backing%' OR NPS_VERBATIM_SPLIT LIKE '%backup%' OR NPS_VERBATIM_SPLIT LIKE '%backup-%' OR NPS_VERBATIM_SPLIT LIKE '%backupped%' OR NPS_VERBATIM_SPLIT LIKE '%backups%' OR NPS_VERBATIM_SPLIT LIKE '%backups-%' OR NPS_VERBATIM_SPLIT LIKE '%bakup%' OR NPS_VERBATIM_SPLIT LIKE '%close%' OR NPS_VERBATIM_SPLIT LIKE '%closed%' OR NPS_VERBATIM_SPLIT LIKE '%closing%' OR NPS_VERBATIM_SPLIT LIKE '%more backup%' OR NPS_VERBATIM_SPLIT LIKE '%open%' OR NPS_VERBATIM_SPLIT LIKE '%opened%' OR NPS_VERBATIM_SPLIT LIKE '%opening%' OR NPS_VERBATIM_SPLIT LIKE '%opens%' OR NPS_VERBATIM_SPLIT LIKE '%pass word%' OR NPS_VERBATIM_SPLIT LIKE '%password%' OR NPS_VERBATIM_SPLIT LIKE '%passwords%' OR NPS_VERBATIM_SPLIT LIKE '%pssword%' OR NPS_VERBATIM_SPLIT LIKE '%re-store%' OR NPS_VERBATIM_SPLIT LIKE '%re-stored%' OR NPS_VERBATIM_SPLIT LIKE '%re-storing%' OR NPS_VERBATIM_SPLIT LIKE '%restoration%' OR NPS_VERBATIM_SPLIT LIKE '%restore%' OR NPS_VERBATIM_SPLIT LIKE '%restore-%' OR NPS_VERBATIM_SPLIT LIKE '%restored%' OR NPS_VERBATIM_SPLIT LIKE '%restored-%' OR NPS_VERBATIM_SPLIT LIKE '%restores%' OR NPS_VERBATIM_SPLIT LIKE '%restoring%' OR NPS_VERBATIM_SPLIT LIKE '%user name%' OR NPS_VERBATIM_SPLIT LIKE '%user name/password%' OR NPS_VERBATIM_SPLIT LIKE '%username%' OR NPS_VERBATIM_SPLIT LIKE '%username/password%' OR NPS_VERBATIM_SPLIT LIKE '%6000% %' OR NPS_VERBATIM_SPLIT LIKE '%6001% %' OR NPS_VERBATIM_SPLIT LIKE '%6010% %' OR NPS_VERBATIM_SPLIT LIKE '%6012% %' OR NPS_VERBATIM_SPLIT LIKE '%6032% %' OR NPS_VERBATIM_SPLIT LIKE '%60352% %' OR NPS_VERBATIM_SPLIT LIKE '%6073% %' OR NPS_VERBATIM_SPLIT LIKE '%6094% %' OR NPS_VERBATIM_SPLIT LIKE '%60940% %' OR NPS_VERBATIM_SPLIT LIKE '%6095% %' OR NPS_VERBATIM_SPLIT LIKE '%6098% %' OR NPS_VERBATIM_SPLIT LIKE '%60980% %' OR NPS_VERBATIM_SPLIT LIKE '%60985% %' OR NPS_VERBATIM_SPLIT LIKE '%6101% %' OR NPS_VERBATIM_SPLIT LIKE '%61041379% %' OR NPS_VERBATIM_SPLIT LIKE '%6105% %' OR NPS_VERBATIM_SPLIT LIKE '%6106% %' OR NPS_VERBATIM_SPLIT LIKE '%6109% %' OR NPS_VERBATIM_SPLIT LIKE '%6123% %' OR NPS_VERBATIM_SPLIT LIKE '%6129% %' OR NPS_VERBATIM_SPLIT LIKE '%6130% %' OR NPS_VERBATIM_SPLIT LIKE '%6131% %' OR NPS_VERBATIM_SPLIT LIKE '%6135% %' OR NPS_VERBATIM_SPLIT LIKE '%6138% %' OR NPS_VERBATIM_SPLIT LIKE '%6139% %' OR NPS_VERBATIM_SPLIT LIKE '%6144% %' OR NPS_VERBATIM_SPLIT LIKE '%61440% %' OR NPS_VERBATIM_SPLIT LIKE '%6147% %' OR NPS_VERBATIM_SPLIT LIKE '%6150% %' OR NPS_VERBATIM_SPLIT LIKE '%61500% %' OR NPS_VERBATIM_SPLIT LIKE '%6173% %' OR NPS_VERBATIM_SPLIT LIKE '%6175% %' OR NPS_VERBATIM_SPLIT LIKE '%6176% %' OR NPS_VERBATIM_SPLIT LIKE '%6177% %' OR NPS_VERBATIM_SPLIT LIKE '%61770% %' OR NPS_VERBATIM_SPLIT LIKE '%61780% %' OR NPS_VERBATIM_SPLIT LIKE '%6182% %' OR NPS_VERBATIM_SPLIT LIKE '%6189% %' OR NPS_VERBATIM_SPLIT LIKE '%6190% %' OR NPS_VERBATIM_SPLIT LIKE '%6192% %' OR NPS_VERBATIM_SPLIT LIKE '%6193% %' OR NPS_VERBATIM_SPLIT LIKE '%6209% %' OR NPS_VERBATIM_SPLIT LIKE '%6407% %' OR NPS_VERBATIM_SPLIT LIKE '%6715% %' OR NPS_VERBATIM_SPLIT LIKE '%6718% %' OR NPS_VERBATIM_SPLIT LIKE '%67186431%' OR NPS_VERBATIM_SPLIT LIKE '%6718645% %' OR NPS_VERBATIM_SPLIT LIKE '%67710% %'  AND (NPS_VERBATIM_SPLIT LIKE '%company%' OR NPS_VERBATIM_SPLIT LIKE '%compny%' OR NPS_VERBATIM_SPLIT LIKE '%data%' OR NPS_VERBATIM_SPLIT LIKE '%database%' OR NPS_VERBATIM_SPLIT LIKE '%error%' OR NPS_VERBATIM_SPLIT LIKE '%errors%' OR NPS_VERBATIM_SPLIT LIKE '%fiel%' OR NPS_VERBATIM_SPLIT LIKE '%file%' OR NPS_VERBATIM_SPLIT LIKE '%file-d%' OR NPS_VERBATIM_SPLIT LIKE '%filed%' OR NPS_VERBATIM_SPLIT LIKE '%filed-%' OR NPS_VERBATIM_SPLIT LIKE '%files%' OR NPS_VERBATIM_SPLIT LIKE '%files-%' OR NPS_VERBATIM_SPLIT LIKE '%filing%' OR NPS_VERBATIM_SPLIT LIKE '%problem%' ) AND (NPS_VERBATIM_SPLIT LIKE '%6000% %' OR NPS_VERBATIM_SPLIT LIKE '%6001% %' OR NPS_VERBATIM_SPLIT LIKE '%6010% %' OR NPS_VERBATIM_SPLIT LIKE '%6012% %' OR NPS_VERBATIM_SPLIT LIKE '%6032% %' OR NPS_VERBATIM_SPLIT LIKE '%60352% %' OR NPS_VERBATIM_SPLIT LIKE '%6073% %' OR NPS_VERBATIM_SPLIT LIKE '%6094% %' OR NPS_VERBATIM_SPLIT LIKE '%60940% %' OR NPS_VERBATIM_SPLIT LIKE '%6095% %' OR NPS_VERBATIM_SPLIT LIKE '%6098% %' OR NPS_VERBATIM_SPLIT LIKE '%60980% %' OR NPS_VERBATIM_SPLIT LIKE '%60985% %' OR NPS_VERBATIM_SPLIT LIKE '%6101% %' OR NPS_VERBATIM_SPLIT LIKE '%61041379% %' OR NPS_VERBATIM_SPLIT LIKE '%6105% %' OR NPS_VERBATIM_SPLIT LIKE '%6106% %' OR NPS_VERBATIM_SPLIT LIKE '%6109% %' OR NPS_VERBATIM_SPLIT LIKE '%6123% %' OR NPS_VERBATIM_SPLIT LIKE '%6129% %' OR NPS_VERBATIM_SPLIT LIKE '%6130% %' OR NPS_VERBATIM_SPLIT LIKE '%6131% %' OR NPS_VERBATIM_SPLIT LIKE '%6135% %' OR NPS_VERBATIM_SPLIT LIKE '%6138% %' OR NPS_VERBATIM_SPLIT LIKE '%6139% %' OR NPS_VERBATIM_SPLIT LIKE '%6144% %' OR NPS_VERBATIM_SPLIT LIKE '%61440% %' OR NPS_VERBATIM_SPLIT LIKE '%6147% %' OR NPS_VERBATIM_SPLIT LIKE '%6150% %' OR NPS_VERBATIM_SPLIT LIKE '%61500% %' OR NPS_VERBATIM_SPLIT LIKE '%6173% %' OR NPS_VERBATIM_SPLIT LIKE '%6175% %' OR NPS_VERBATIM_SPLIT LIKE '%6176% %' OR NPS_VERBATIM_SPLIT LIKE '%6177% %' OR NPS_VERBATIM_SPLIT LIKE '%61770% %' OR NPS_VERBATIM_SPLIT LIKE '%61780% %' OR NPS_VERBATIM_SPLIT LIKE '%6182% %' OR NPS_VERBATIM_SPLIT LIKE '%6189% %' OR NPS_VERBATIM_SPLIT LIKE '%6190% %' OR NPS_VERBATIM_SPLIT LIKE '%6192% %' OR NPS_VERBATIM_SPLIT LIKE '%6193% %' OR NPS_VERBATIM_SPLIT LIKE '%6209% %' OR NPS_VERBATIM_SPLIT LIKE '%6407% %' OR NPS_VERBATIM_SPLIT LIKE '%6715% %' OR NPS_VERBATIM_SPLIT LIKE '%6718% %' OR NPS_VERBATIM_SPLIT LIKE '%67186431%' OR NPS_VERBATIM_SPLIT LIKE '%6718645% %' OR NPS_VERBATIM_SPLIT LIKE '%67710% %' ) THEN 'Platform'
 END AS CAT 
 FROM USG_SBG_WS..NPS_VERBATIM_SUBSTRING
 UNION 
 SELECT *, CASE 
 WHEN NPS_VERBATIM_SPLIT LIKE '%report% %'  THEN 'Reporting'
 END AS CAT 
 FROM USG_SBG_WS..NPS_VERBATIM_SUBSTRING
 UNION 
 SELECT *, CASE 
 WHEN NPS_VERBATIM_SPLIT LIKE '%directories%' OR NPS_VERBATIM_SPLIT LIKE '%directory%' OR NPS_VERBATIM_SPLIT LIKE '%firewall%' OR NPS_VERBATIM_SPLIT LIKE '%firewalls%' OR NPS_VERBATIM_SPLIT LIKE '%ports%' OR NPS_VERBATIM_SPLIT LIKE '%security%'  THEN 'Security'
 END AS CAT 
 FROM USG_SBG_WS..NPS_VERBATIM_SUBSTRING
 UNION 
 SELECT *, CASE 
 WHEN NPS_VERBATIM_SPLIT LIKE '%export%' OR NPS_VERBATIM_SPLIT LIKE '%exported%' OR NPS_VERBATIM_SPLIT LIKE '%exporting%' OR NPS_VERBATIM_SPLIT LIKE '%exports%' OR NPS_VERBATIM_SPLIT LIKE '%import%' OR NPS_VERBATIM_SPLIT LIKE '%imported%' OR NPS_VERBATIM_SPLIT LIKE '%importing%' OR NPS_VERBATIM_SPLIT LIKE '%imports 182004% %'  THEN 'Import / Export'
 END AS CAT 
 FROM USG_SBG_WS..NPS_VERBATIM_SUBSTRING
 UNION 
 SELECT *, CASE 
 WHEN NPS_VERBATIM_SPLIT LIKE '%driver%' OR NPS_VERBATIM_SPLIT LIKE '%epson%' OR NPS_VERBATIM_SPLIT LIKE '%print%' OR NPS_VERBATIM_SPLIT LIKE '%printed%' OR NPS_VERBATIM_SPLIT LIKE '%printer%' OR NPS_VERBATIM_SPLIT LIKE '%printers%' OR NPS_VERBATIM_SPLIT LIKE '%printing%' OR NPS_VERBATIM_SPLIT LIKE '%prints%' OR NPS_VERBATIM_SPLIT LIKE '%zebra%'  THEN 'Printing'
 END AS CAT 
 FROM USG_SBG_WS..NPS_VERBATIM_SUBSTRING
 UNION 
 SELECT *, CASE 
 WHEN NPS_VERBATIM_SPLIT LIKE '%payments%' OR NPS_VERBATIM_SPLIT LIKE '%purchase order%' OR NPS_VERBATIM_SPLIT LIKE '%purchase orders%' OR NPS_VERBATIM_SPLIT LIKE '%receipt% %' OR NPS_VERBATIM_SPLIT LIKE '%receive payments%' OR NPS_VERBATIM_SPLIT LIKE '%received payment%' OR NPS_VERBATIM_SPLIT LIKE '%reciept% %' OR NPS_VERBATIM_SPLIT LIKE '%recieve payment%' OR NPS_VERBATIM_SPLIT LIKE '%recieved payment%' OR NPS_VERBATIM_SPLIT LIKE '%sales order%' OR NPS_VERBATIM_SPLIT LIKE '%sales orders%' OR NPS_VERBATIM_SPLIT LIKE '%sales receipt%' OR NPS_VERBATIM_SPLIT LIKE '%sales receipts%' OR NPS_VERBATIM_SPLIT LIKE '%sales reciept%' OR NPS_VERBATIM_SPLIT LIKE '%sales reciepts%' OR NPS_VERBATIM_SPLIT LIKE '%statement%' OR NPS_VERBATIM_SPLIT LIKE '%statements%' OR NPS_VERBATIM_SPLIT LIKE '%transaction%' OR NPS_VERBATIM_SPLIT LIKE '%transactions%' OR NPS_VERBATIM_SPLIT LIKE '%txn%' OR NPS_VERBATIM_SPLIT LIKE '%voucher% %' OR NPS_VERBATIM_SPLIT LIKE '%bill%' OR NPS_VERBATIM_SPLIT LIKE '%bills%' OR NPS_VERBATIM_SPLIT LIKE '%bills-%' OR NPS_VERBATIM_SPLIT LIKE '%cc%' OR NPS_VERBATIM_SPLIT LIKE '%ccards%' OR NPS_VERBATIM_SPLIT LIKE '%check%' OR NPS_VERBATIM_SPLIT LIKE '%check-%' OR NPS_VERBATIM_SPLIT LIKE '%checking%' OR NPS_VERBATIM_SPLIT LIKE '%checks%' OR NPS_VERBATIM_SPLIT LIKE '%checks-%' OR NPS_VERBATIM_SPLIT LIKE '%credit card%' OR NPS_VERBATIM_SPLIT LIKE '%credit cards%' OR NPS_VERBATIM_SPLIT LIKE '%credit memo%' OR NPS_VERBATIM_SPLIT LIKE '%credit memos%' OR NPS_VERBATIM_SPLIT LIKE '%customer payment%' OR NPS_VERBATIM_SPLIT LIKE '%debit card%' OR NPS_VERBATIM_SPLIT LIKE '%deposit%' OR NPS_VERBATIM_SPLIT LIKE '%deposits%' OR NPS_VERBATIM_SPLIT LIKE '%estimate%' OR NPS_VERBATIM_SPLIT LIKE '%estimates%' OR NPS_VERBATIM_SPLIT LIKE '%invoice%' OR NPS_VERBATIM_SPLIT LIKE '%invoice% %' OR NPS_VERBATIM_SPLIT LIKE '%invoiced%' OR NPS_VERBATIM_SPLIT LIKE '%invoices%' OR NPS_VERBATIM_SPLIT LIKE '%invoicing%' OR NPS_VERBATIM_SPLIT LIKE '%item receipt%' OR NPS_VERBATIM_SPLIT LIKE '%item receipts%' OR NPS_VERBATIM_SPLIT LIKE '%journal entries%' OR NPS_VERBATIM_SPLIT LIKE '%journal entry%' OR NPS_VERBATIM_SPLIT LIKE '%layaway%' OR NPS_VERBATIM_SPLIT LIKE '%more check%' OR NPS_VERBATIM_SPLIT LIKE '%outlook%' OR NPS_VERBATIM_SPLIT LIKE '%paycheck%' OR NPS_VERBATIM_SPLIT LIKE '%paychecks%' OR NPS_VERBATIM_SPLIT LIKE '%payment%'  AND (NPS_VERBATIM_SPLIT NOT LIKE '%amazon%' AND NPS_VERBATIM_SPLIT NOT LIKE '%bill me%' AND NPS_VERBATIM_SPLIT NOT LIKE '%charge my credit card%' AND NPS_VERBATIM_SPLIT NOT LIKE '%charge% %' AND NPS_VERBATIM_SPLIT NOT LIKE '%check it out%' AND NPS_VERBATIM_SPLIT NOT LIKE '%check this out%' AND NPS_VERBATIM_SPLIT NOT LIKE '%checkmark%' AND NPS_VERBATIM_SPLIT NOT LIKE '%export%' AND NPS_VERBATIM_SPLIT NOT LIKE '%import%' AND NPS_VERBATIM_SPLIT NOT LIKE '%mark%' AND NPS_VERBATIM_SPLIT NOT LIKE '%online bill pay%' AND NPS_VERBATIM_SPLIT NOT LIKE '%payroll service%' AND NPS_VERBATIM_SPLIT NOT LIKE '%plan%' AND NPS_VERBATIM_SPLIT NOT LIKE '%privacy%' AND NPS_VERBATIM_SPLIT NOT LIKE '%profit and loss%' AND NPS_VERBATIM_SPLIT NOT LIKE '%renew%' AND NPS_VERBATIM_SPLIT NOT LIKE '%status%' AND NPS_VERBATIM_SPLIT NOT LIKE '%update information%' AND NPS_VERBATIM_SPLIT NOT LIKE '%update the cc%' AND NPS_VERBATIM_SPLIT NOT LIKE '%update the credit card%' ) THEN 'Transactions'
 END AS CAT 
 FROM USG_SBG_WS..NPS_VERBATIM_SUBSTRING
 UNION 
 SELECT *, CASE 
 WHEN NPS_VERBATIM_SPLIT LIKE '%acccountant copy%' OR NPS_VERBATIM_SPLIT LIKE '%copied%' OR NPS_VERBATIM_SPLIT LIKE '%copies%' OR NPS_VERBATIM_SPLIT LIKE '%copy%' OR NPS_VERBATIM_SPLIT LIKE '%copying%' OR NPS_VERBATIM_SPLIT LIKE '%create%' OR NPS_VERBATIM_SPLIT LIKE '%created%' OR NPS_VERBATIM_SPLIT LIKE '%creates%' OR NPS_VERBATIM_SPLIT LIKE '%creating%' OR NPS_VERBATIM_SPLIT LIKE '%delete%' OR NPS_VERBATIM_SPLIT LIKE '%deleted%' OR NPS_VERBATIM_SPLIT LIKE '%deletes%' OR NPS_VERBATIM_SPLIT LIKE '%deleting%' OR NPS_VERBATIM_SPLIT LIKE '%find%' OR NPS_VERBATIM_SPLIT LIKE '%finded%' OR NPS_VERBATIM_SPLIT LIKE '%finding%' OR NPS_VERBATIM_SPLIT LIKE '%found%' OR NPS_VERBATIM_SPLIT LIKE '%locate%' OR NPS_VERBATIM_SPLIT LIKE '%located%' OR NPS_VERBATIM_SPLIT LIKE '%locating%' OR NPS_VERBATIM_SPLIT LIKE '%move%' OR NPS_VERBATIM_SPLIT LIKE '%moved%' OR NPS_VERBATIM_SPLIT LIKE '%moving%' OR NPS_VERBATIM_SPLIT LIKE '%rename%' OR NPS_VERBATIM_SPLIT LIKE '%renamed%' OR NPS_VERBATIM_SPLIT LIKE '%renames%' OR NPS_VERBATIM_SPLIT LIKE '%renaming%' OR NPS_VERBATIM_SPLIT LIKE '%save%' OR NPS_VERBATIM_SPLIT LIKE '%saved%' OR NPS_VERBATIM_SPLIT LIKE '%saveing%' OR NPS_VERBATIM_SPLIT LIKE '%saves%' OR NPS_VERBATIM_SPLIT LIKE '%saving%' OR NPS_VERBATIM_SPLIT LIKE '%send%' OR NPS_VERBATIM_SPLIT LIKE '%sending%' OR NPS_VERBATIM_SPLIT LIKE '%sends%' OR NPS_VERBATIM_SPLIT LIKE '%sent%' OR NPS_VERBATIM_SPLIT LIKE '%transfer%' OR NPS_VERBATIM_SPLIT LIKE '%transferred%' OR NPS_VERBATIM_SPLIT LIKE '%transfers%'  AND (NPS_VERBATIM_SPLIT LIKE '%company%' OR NPS_VERBATIM_SPLIT LIKE '%data%' OR NPS_VERBATIM_SPLIT LIKE '%database%' OR NPS_VERBATIM_SPLIT LIKE '%fiel%' OR NPS_VERBATIM_SPLIT LIKE '%file%' OR NPS_VERBATIM_SPLIT LIKE '%file-d%' OR NPS_VERBATIM_SPLIT LIKE '%filed%' OR NPS_VERBATIM_SPLIT LIKE '%filed-%' OR NPS_VERBATIM_SPLIT LIKE '%files%' OR NPS_VERBATIM_SPLIT LIKE '%files-%' OR NPS_VERBATIM_SPLIT LIKE '%filing%' ) AND (NPS_VERBATIM_SPLIT NOT LIKE '%.exe%' AND NPS_VERBATIM_SPLIT NOT LIKE '%.lbg%' AND NPS_VERBATIM_SPLIT NOT LIKE '%.qbp%' AND NPS_VERBATIM_SPLIT NOT LIKE '%.qpb%' AND NPS_VERBATIM_SPLIT NOT LIKE '%.tlg%' AND NPS_VERBATIM_SPLIT NOT LIKE '%account%' AND NPS_VERBATIM_SPLIT NOT LIKE '%application%' AND NPS_VERBATIM_SPLIT NOT LIKE '%back up%' AND NPS_VERBATIM_SPLIT NOT LIKE '%backing%' AND NPS_VERBATIM_SPLIT NOT LIKE '%backup%' AND NPS_VERBATIM_SPLIT NOT LIKE '%backup% %' AND NPS_VERBATIM_SPLIT NOT LIKE '%bill%' AND NPS_VERBATIM_SPLIT NOT LIKE '%billed%' AND NPS_VERBATIM_SPLIT NOT LIKE '%billed-%' AND NPS_VERBATIM_SPLIT NOT LIKE '%billing%' AND NPS_VERBATIM_SPLIT NOT LIKE '%bills%' AND NPS_VERBATIM_SPLIT NOT LIKE '%bills-%' AND NPS_VERBATIM_SPLIT NOT LIKE '%cc%' AND NPS_VERBATIM_SPLIT NOT LIKE '%ccards%' AND NPS_VERBATIM_SPLIT NOT LIKE '%check%' AND NPS_VERBATIM_SPLIT NOT LIKE '%check-%' AND NPS_VERBATIM_SPLIT NOT LIKE '%checked%' AND NPS_VERBATIM_SPLIT NOT LIKE '%checking%' AND NPS_VERBATIM_SPLIT NOT LIKE '%checks%' AND NPS_VERBATIM_SPLIT NOT LIKE '%checks-%' AND NPS_VERBATIM_SPLIT NOT LIKE '%credit card%' AND NPS_VERBATIM_SPLIT NOT LIKE '%credit cards%' AND NPS_VERBATIM_SPLIT NOT LIKE '%credit memo%' AND NPS_VERBATIM_SPLIT NOT LIKE '%credit memos%' AND NPS_VERBATIM_SPLIT NOT LIKE '%customer payment%' AND NPS_VERBATIM_SPLIT NOT LIKE '%deposit%' AND NPS_VERBATIM_SPLIT NOT LIKE '%deposits%' AND NPS_VERBATIM_SPLIT NOT LIKE '%disc%' AND NPS_VERBATIM_SPLIT NOT LIKE '%disk%' AND NPS_VERBATIM_SPLIT NOT LIKE '%e file%' AND NPS_VERBATIM_SPLIT NOT LIKE '%e-file%' AND NPS_VERBATIM_SPLIT NOT LIKE '%efile%' AND NPS_VERBATIM_SPLIT NOT LIKE '%estimate%' AND NPS_VERBATIM_SPLIT NOT LIKE '%estimates%' AND NPS_VERBATIM_SPLIT NOT LIKE '%export%' AND NPS_VERBATIM_SPLIT NOT LIKE '%govt%' AND NPS_VERBATIM_SPLIT NOT LIKE '%id%' AND NPS_VERBATIM_SPLIT NOT LIKE '%import%' AND NPS_VERBATIM_SPLIT NOT LIKE '%information%' AND NPS_VERBATIM_SPLIT NOT LIKE '%install%' AND NPS_VERBATIM_SPLIT NOT LIKE '%install-%' AND NPS_VERBATIM_SPLIT NOT LIKE '%installed%' AND NPS_VERBATIM_SPLIT NOT LIKE '%installed-%' AND NPS_VERBATIM_SPLIT NOT LIKE '%installing%' AND NPS_VERBATIM_SPLIT NOT LIKE '%installing-%' AND NPS_VERBATIM_SPLIT NOT LIKE '%installs%' AND NPS_VERBATIM_SPLIT NOT LIKE '%invoice%' AND NPS_VERBATIM_SPLIT NOT LIKE '%invoice-%' AND NPS_VERBATIM_SPLIT NOT LIKE '%invoiced%' AND NPS_VERBATIM_SPLIT NOT LIKE '%invoices%' AND NPS_VERBATIM_SPLIT NOT LIKE '%invoices-%' AND NPS_VERBATIM_SPLIT NOT LIKE '%invoicing%' AND NPS_VERBATIM_SPLIT NOT LIKE '%invoicing-%' AND NPS_VERBATIM_SPLIT NOT LIKE '%item receipt%' AND NPS_VERBATIM_SPLIT NOT LIKE '%item receipts%' AND NPS_VERBATIM_SPLIT NOT LIKE '%journal entries%' AND NPS_VERBATIM_SPLIT NOT LIKE '%journal entry%' AND NPS_VERBATIM_SPLIT NOT LIKE '%log%' AND NPS_VERBATIM_SPLIT NOT LIKE '%more check%' AND NPS_VERBATIM_SPLIT NOT LIKE '%paycheck%' AND NPS_VERBATIM_SPLIT NOT LIKE '%paychecks%' AND NPS_VERBATIM_SPLIT NOT LIKE '%payment%' AND NPS_VERBATIM_SPLIT NOT LIKE '%payments%' AND NPS_VERBATIM_SPLIT NOT LIKE '%pdf%' AND NPS_VERBATIM_SPLIT NOT LIKE '%preference%' AND NPS_VERBATIM_SPLIT NOT LIKE '%preferences%' AND NPS_VERBATIM_SPLIT NOT LIKE '%print%' AND NPS_VERBATIM_SPLIT NOT LIKE '%printer%' AND NPS_VERBATIM_SPLIT NOT LIKE '%purchase order%' AND NPS_VERBATIM_SPLIT NOT LIKE '%purchase orders%' AND NPS_VERBATIM_SPLIT NOT LIKE '%qbregistration%' AND NPS_VERBATIM_SPLIT NOT LIKE '%qpb%' AND NPS_VERBATIM_SPLIT NOT LIKE '%reach%' AND NPS_VERBATIM_SPLIT NOT LIKE '%read only%' AND NPS_VERBATIM_SPLIT NOT LIKE '%read-only%' AND NPS_VERBATIM_SPLIT NOT LIKE '%receive payments%' AND NPS_VERBATIM_SPLIT NOT LIKE '%received payment%' AND NPS_VERBATIM_SPLIT NOT LIKE '%recieve payment%' AND NPS_VERBATIM_SPLIT NOT LIKE '%recieved payment%' AND NPS_VERBATIM_SPLIT NOT LIKE '%registration.dat%' AND NPS_VERBATIM_SPLIT NOT LIKE '%sales order%' AND NPS_VERBATIM_SPLIT NOT LIKE '%sales orders%' AND NPS_VERBATIM_SPLIT NOT LIKE '%sales receipts%' AND NPS_VERBATIM_SPLIT NOT LIKE '%sales reciept%' AND NPS_VERBATIM_SPLIT NOT LIKE '%slip%' AND NPS_VERBATIM_SPLIT NOT LIKE '%slips%' AND NPS_VERBATIM_SPLIT NOT LIKE '%statement%' AND NPS_VERBATIM_SPLIT NOT LIKE '%statements%' AND NPS_VERBATIM_SPLIT NOT LIKE '%transaction%' AND NPS_VERBATIM_SPLIT NOT LIKE '%transactions%' AND NPS_VERBATIM_SPLIT NOT LIKE '%txn%' ) THEN 'File Actions'
 END AS CAT 
 FROM USG_SBG_WS..NPS_VERBATIM_SUBSTRING
 UNION 
 SELECT *, CASE 
 WHEN NPS_VERBATIM_SPLIT LIKE '%ein%' OR NPS_VERBATIM_SPLIT LIKE '%payrol%' OR NPS_VERBATIM_SPLIT LIKE '%payroll%'  THEN 'Payroll'
 END AS CAT 
 FROM USG_SBG_WS..NPS_VERBATIM_SUBSTRING
 UNION 
 SELECT *, CASE 
 WHEN NPS_VERBATIM_SPLIT LIKE '%account%' OR NPS_VERBATIM_SPLIT LIKE '%accounts%'  AND (NPS_VERBATIM_SPLIT LIKE '%activate%' OR NPS_VERBATIM_SPLIT LIKE '%activated%' OR NPS_VERBATIM_SPLIT LIKE '%activates%' OR NPS_VERBATIM_SPLIT LIKE '%activating%' OR NPS_VERBATIM_SPLIT LIKE '%balance%' OR NPS_VERBATIM_SPLIT LIKE '%balances%' OR NPS_VERBATIM_SPLIT LIKE '%check%' OR NPS_VERBATIM_SPLIT LIKE '%creaeted%' OR NPS_VERBATIM_SPLIT LIKE '%create%' OR NPS_VERBATIM_SPLIT LIKE '%created%' OR NPS_VERBATIM_SPLIT LIKE '%creates%' OR NPS_VERBATIM_SPLIT LIKE '%creating%' OR NPS_VERBATIM_SPLIT LIKE '%delete%' OR NPS_VERBATIM_SPLIT LIKE '%deleted%' OR NPS_VERBATIM_SPLIT LIKE '%deleting%' OR NPS_VERBATIM_SPLIT LIKE '%find%' OR NPS_VERBATIM_SPLIT LIKE '%finding%' OR NPS_VERBATIM_SPLIT LIKE '%finds%' OR NPS_VERBATIM_SPLIT LIKE '%fund%' OR NPS_VERBATIM_SPLIT LIKE '%funds%' OR NPS_VERBATIM_SPLIT LIKE '%locate%' OR NPS_VERBATIM_SPLIT LIKE '%located%' OR NPS_VERBATIM_SPLIT LIKE '%locates%' OR NPS_VERBATIM_SPLIT LIKE '%locating%' OR NPS_VERBATIM_SPLIT LIKE '%merge%' OR NPS_VERBATIM_SPLIT LIKE '%merged%' OR NPS_VERBATIM_SPLIT LIKE '%merges%' OR NPS_VERBATIM_SPLIT LIKE '%merging%' OR NPS_VERBATIM_SPLIT LIKE '%reconcile%' OR NPS_VERBATIM_SPLIT LIKE '%reconciled%' OR NPS_VERBATIM_SPLIT LIKE '%reconciles%' OR NPS_VERBATIM_SPLIT LIKE '%reconciling%' OR NPS_VERBATIM_SPLIT LIKE '%show%' OR NPS_VERBATIM_SPLIT LIKE '%showing%' OR NPS_VERBATIM_SPLIT LIKE '%shows%' OR NPS_VERBATIM_SPLIT LIKE '%work%' ) AND (NPS_VERBATIM_SPLIT NOT LIKE '%cancelled%' AND NPS_VERBATIM_SPLIT NOT LIKE '%cancels%' AND NPS_VERBATIM_SPLIT NOT LIKE '%charg%' AND NPS_VERBATIM_SPLIT NOT LIKE '%charge%' AND NPS_VERBATIM_SPLIT NOT LIKE '%charges%' AND NPS_VERBATIM_SPLIT NOT LIKE '%merchant%' AND NPS_VERBATIM_SPLIT NOT LIKE '%olbu%' AND NPS_VERBATIM_SPLIT NOT LIKE '%online backup%' AND NPS_VERBATIM_SPLIT NOT LIKE '%order%' AND NPS_VERBATIM_SPLIT NOT LIKE '%refund%' AND NPS_VERBATIM_SPLIT NOT LIKE '%report%' AND NPS_VERBATIM_SPLIT NOT LIKE '%tech support%' AND NPS_VERBATIM_SPLIT NOT LIKE '%backup%' AND NPS_VERBATIM_SPLIT NOT LIKE '%cancel%' ) THEN 'Account'
 END AS CAT 
 FROM USG_SBG_WS..NPS_VERBATIM_SUBSTRING
 UNION 
 SELECT *, CASE 
 WHEN NPS_VERBATIM_SPLIT LIKE '%assembly%' OR NPS_VERBATIM_SPLIT LIKE '%item%' OR NPS_VERBATIM_SPLIT LIKE '%items%' OR NPS_VERBATIM_SPLIT LIKE '%non inv%' OR NPS_VERBATIM_SPLIT LIKE '%non inventory%' OR NPS_VERBATIM_SPLIT LIKE '%price level%' OR NPS_VERBATIM_SPLIT LIKE '%price levels%' OR NPS_VERBATIM_SPLIT LIKE '%pricelevel%' OR NPS_VERBATIM_SPLIT LIKE '%pricelevels%' OR NPS_VERBATIM_SPLIT LIKE '%unit of measure%'  AND (NPS_VERBATIM_SPLIT NOT LIKE '%exchange%' AND NPS_VERBATIM_SPLIT NOT LIKE '%export%' AND NPS_VERBATIM_SPLIT NOT LIKE '%exported%' AND NPS_VERBATIM_SPLIT NOT LIKE '%exporting%' AND NPS_VERBATIM_SPLIT NOT LIKE '%exports%' AND NPS_VERBATIM_SPLIT NOT LIKE '%fe%' AND NPS_VERBATIM_SPLIT NOT LIKE '%fin%' AND NPS_VERBATIM_SPLIT NOT LIKE '%financail%' AND NPS_VERBATIM_SPLIT NOT LIKE '%financial%' AND NPS_VERBATIM_SPLIT NOT LIKE '%financiel%' AND NPS_VERBATIM_SPLIT NOT LIKE '%finanial%' AND NPS_VERBATIM_SPLIT NOT LIKE '%finanical%' AND NPS_VERBATIM_SPLIT NOT LIKE '%finencial%' AND NPS_VERBATIM_SPLIT NOT LIKE '%import%' AND NPS_VERBATIM_SPLIT NOT LIKE '%imported%' AND NPS_VERBATIM_SPLIT NOT LIKE '%importing%' AND NPS_VERBATIM_SPLIT NOT LIKE '%imports%' AND NPS_VERBATIM_SPLIT NOT LIKE '%rds%' AND NPS_VERBATIM_SPLIT NOT LIKE '%remote data sharing%' AND NPS_VERBATIM_SPLIT NOT LIKE '%report%' AND NPS_VERBATIM_SPLIT NOT LIKE '%report-%' AND NPS_VERBATIM_SPLIT NOT LIKE '%reported%' AND NPS_VERBATIM_SPLIT NOT LIKE '%reporting%' AND NPS_VERBATIM_SPLIT NOT LIKE '%reports%' AND NPS_VERBATIM_SPLIT NOT LIKE '%reports-%' AND NPS_VERBATIM_SPLIT NOT LIKE '%use%' AND NPS_VERBATIM_SPLIT NOT LIKE '%used%' AND NPS_VERBATIM_SPLIT NOT LIKE '%using ship% %' ) THEN 'Items'
 END AS CAT 
 FROM USG_SBG_WS..NPS_VERBATIM_SUBSTRING
 UNION 
 SELECT *, CASE 
 WHEN NPS_VERBATIM_SPLIT LIKE '%bar code scanner%' OR NPS_VERBATIM_SPLIT LIKE '%barcode scanner%' OR NPS_VERBATIM_SPLIT LIKE '%card reader%' OR NPS_VERBATIM_SPLIT LIKE '%card swipe%' OR NPS_VERBATIM_SPLIT LIKE '%cash drawer%' OR NPS_VERBATIM_SPLIT LIKE '%cash register%' OR NPS_VERBATIM_SPLIT LIKE '%cashdrawer%' OR NPS_VERBATIM_SPLIT LIKE '%cc reader%' OR NPS_VERBATIM_SPLIT LIKE '%citizen%' OR NPS_VERBATIM_SPLIT LIKE '%cognitive%' OR NPS_VERBATIM_SPLIT LIKE '%cognitive del sol%' OR NPS_VERBATIM_SPLIT LIKE '%credit card reader%' OR NPS_VERBATIM_SPLIT LIKE '%del sol%' OR NPS_VERBATIM_SPLIT LIKE '%epson%' OR NPS_VERBATIM_SPLIT LIKE '%hardware%' OR NPS_VERBATIM_SPLIT LIKE '%inventory scanner%' OR NPS_VERBATIM_SPLIT LIKE '%label printer%' OR NPS_VERBATIM_SPLIT LIKE '%lp 2824%' OR NPS_VERBATIM_SPLIT LIKE '%lp 2844%' OR NPS_VERBATIM_SPLIT LIKE '%lp2824%' OR NPS_VERBATIM_SPLIT LIKE '%lp2844%' OR NPS_VERBATIM_SPLIT LIKE '%metro logic%' OR NPS_VERBATIM_SPLIT LIKE '%metrologic%' OR NPS_VERBATIM_SPLIT LIKE '%money drawer%' OR NPS_VERBATIM_SPLIT LIKE '%pdt%' OR NPS_VERBATIM_SPLIT LIKE '%physical inventory scanner%' OR NPS_VERBATIM_SPLIT LIKE '%pin pad%' OR NPS_VERBATIM_SPLIT LIKE '%pinpad%' OR NPS_VERBATIM_SPLIT LIKE '%pole display%' OR NPS_VERBATIM_SPLIT LIKE '%receipt printer%' OR NPS_VERBATIM_SPLIT LIKE '%reciept printer%' OR NPS_VERBATIM_SPLIT LIKE '%scanner%' OR NPS_VERBATIM_SPLIT LIKE '%swipe%' OR NPS_VERBATIM_SPLIT LIKE '%swiper%' OR NPS_VERBATIM_SPLIT LIKE '%tag printer%' OR NPS_VERBATIM_SPLIT LIKE '%tsp%' OR NPS_VERBATIM_SPLIT LIKE '%zebra%'  THEN 'Hardware'
 END AS CAT 
 FROM USG_SBG_WS..NPS_VERBATIM_SUBSTRING
 UNION 
 SELECT *, CASE 
 WHEN NPS_VERBATIM_SPLIT LIKE '%new version%' OR NPS_VERBATIM_SPLIT LIKE '%new versions%' OR NPS_VERBATIM_SPLIT LIKE '%newer version%' OR NPS_VERBATIM_SPLIT LIKE '%newer versions%' OR NPS_VERBATIM_SPLIT LIKE '%sunset%' OR NPS_VERBATIM_SPLIT LIKE '%sunsetted%'  THEN 'New Version'
 END AS CAT 
 FROM USG_SBG_WS..NPS_VERBATIM_SUBSTRING
 UNION 
 SELECT *, CASE 
 WHEN NPS_VERBATIM_SPLIT LIKE '%cost%' OR NPS_VERBATIM_SPLIT LIKE '%dollars%' OR NPS_VERBATIM_SPLIT LIKE '%expensive%' OR NPS_VERBATIM_SPLIT LIKE '%money%' OR NPS_VERBATIM_SPLIT LIKE '%paid%' OR NPS_VERBATIM_SPLIT LIKE '%pay%' OR NPS_VERBATIM_SPLIT LIKE '%paying%' OR NPS_VERBATIM_SPLIT LIKE '%price%'  AND (NPS_VERBATIM_SPLIT LIKE '%customer manager%' OR NPS_VERBATIM_SPLIT LIKE '%enterprise solutions%' OR NPS_VERBATIM_SPLIT LIKE '%es qbes%' OR NPS_VERBATIM_SPLIT LIKE '%pos%' OR NPS_VERBATIM_SPLIT LIKE '%premeir%' OR NPS_VERBATIM_SPLIT LIKE '%premier%' OR NPS_VERBATIM_SPLIT LIKE '%pro%' OR NPS_VERBATIM_SPLIT LIKE '%product%' OR NPS_VERBATIM_SPLIT LIKE '%program%' OR NPS_VERBATIM_SPLIT LIKE '%qb%' OR NPS_VERBATIM_SPLIT LIKE '%qbpro%' OR NPS_VERBATIM_SPLIT LIKE '%quick books%' OR NPS_VERBATIM_SPLIT LIKE '%quickbooks%' OR NPS_VERBATIM_SPLIT LIKE '%simple start%' OR NPS_VERBATIM_SPLIT LIKE '%software%' OR NPS_VERBATIM_SPLIT LIKE '%ss%' OR NPS_VERBATIM_SPLIT LIKE '%velocity%' ) AND (NPS_VERBATIM_SPLIT NOT LIKE '%consultant%' AND NPS_VERBATIM_SPLIT NOT LIKE '%rep%' AND NPS_VERBATIM_SPLIT NOT LIKE '%representative%' AND NPS_VERBATIM_SPLIT NOT LIKE '%reps%' AND NPS_VERBATIM_SPLIT NOT LIKE '%service%' AND NPS_VERBATIM_SPLIT NOT LIKE '%site%' AND NPS_VERBATIM_SPLIT NOT LIKE '%support%' AND NPS_VERBATIM_SPLIT NOT LIKE '%web%' AND NPS_VERBATIM_SPLIT NOT LIKE '%web page%' AND NPS_VERBATIM_SPLIT NOT LIKE '%website%' AND NPS_VERBATIM_SPLIT NOT LIKE '%tech% %' AND NPS_VERBATIM_SPLIT NOT LIKE '%agent% %' AND NPS_VERBATIM_SPLIT NOT LIKE '%knowledg% %' ) THEN 'Product Price'
 END AS CAT 
 FROM USG_SBG_WS..NPS_VERBATIM_SUBSTRING
 UNION 
 SELECT *, CASE 
 WHEN NPS_VERBATIM_SPLIT LIKE '%bug%' OR NPS_VERBATIM_SPLIT LIKE '%bugs%'  THEN 'Bug'
 END AS CAT 
 FROM USG_SBG_WS..NPS_VERBATIM_SUBSTRING
 UNION 
 SELECT *, CASE 
 WHEN NPS_VERBATIM_SPLIT LIKE '%feature%' OR NPS_VERBATIM_SPLIT LIKE '%features%'  THEN 'Features'
 END AS CAT 
 FROM USG_SBG_WS..NPS_VERBATIM_SUBSTRING
 UNION 
 SELECT *, CASE 
 WHEN NPS_VERBATIM_SPLIT LIKE '%intuit sync manager%' OR NPS_VERBATIM_SPLIT LIKE '%qb connect%' OR NPS_VERBATIM_SPLIT LIKE '%qb connect lite%' OR NPS_VERBATIM_SPLIT LIKE '%qbconnect%' OR NPS_VERBATIM_SPLIT LIKE '%qbconnect lite%' OR NPS_VERBATIM_SPLIT LIKE '%qb connect light%' OR NPS_VERBATIM_SPLIT LIKE '%qbconnect light%' OR NPS_VERBATIM_SPLIT LIKE '%qbconnectlite%' OR NPS_VERBATIM_SPLIT LIKE '%qbconnectlight%' OR NPS_VERBATIM_SPLIT LIKE '%sync manager%'  THEN 'Connected Services'
 END AS CAT 
 FROM USG_SBG_WS..NPS_VERBATIM_SUBSTRING) UNIONS
 WHERE CAT IS NOT NULL; 
 
         
 
 
 
 
 
