-- Semantic View DDL (not included in schema-level GET_DDL dump) — extracted 2026-08-17
create or replace semantic view SV_LOGISTICS
	tables (
		BOL as MENDIX_APP.AGENTS.BILL_OF_LADING primary key (BL_ID) with synonyms=('bill of lading','shipments','BL') comment='Core shipment / Bill of Lading fact table',
		PORT_LOAD as MENDIX_APP.AGENTS.PORT_MASTER primary key (PORT_CODE) with synonyms=('loading port','origin port','seaport') comment='Seaport reference data (used here as port of loading)',
		PORT_DISCHARGE as MENDIX_APP.AGENTS.PORT_MASTER primary key (PORT_CODE) with synonyms=('discharge port','destination port') comment='Seaport reference data (used here as port of discharge)',
		VESSEL as MENDIX_APP.AGENTS.VESSEL_REGISTRY primary key (VESSEL_NAME) with synonyms=('ship','vessel') comment='Vessel registry reference',
		HS as MENDIX_APP.AGENTS.HS_CODE_REFERENCE primary key (HS_CODE) with synonyms=('commodity code','HS code') comment='HS code / commodity classification reference'
	)
	relationships (
		BOL_TO_HS as BOL(HS_CODE) references HS(HS_CODE),
		BOL_TO_PORT_DISCHARGE as BOL(PORT_OF_DISCHARGE_LOCODE) references PORT_DISCHARGE(PORT_CODE),
		BOL_TO_PORT_LOAD as BOL(PORT_OF_LOADING_LOCODE) references PORT_LOAD(PORT_CODE),
		BOL_TO_VESSEL as BOL(VESSEL_NAME) references VESSEL(VESSEL_NAME)
	)
	facts (
		BOL.GROSS_WEIGHT_KGS as GROSS_WEIGHT_KGS,
		BOL.TOTAL_CHARGES as TOTAL_CHARGES,
		BOL.FREIGHT_AMOUNT as FREIGHT_AMOUNT,
		BOL.PACKAGE_COUNT as PACKAGE_COUNT,
		BOL.VOLUME_CBM as VOLUME_CBM
	)
	dimensions (
		BOL.BL_NUMBER as BL_NUMBER,
		BOL.CARRIER_NAME as CARRIER_NAME with synonyms=('shipping line','carrier'),
		BOL.STATUS as STATUS,
		BOL.SHIPPER_NAME as SHIPPER_NAME,
		BOL.CONSIGNEE_NAME as CONSIGNEE_NAME,
		BOL.BL_DATE as BL_DATE,
		BOL.ETD as ETD,
		BOL.ETA as ETA,
		BOL.IS_DANGEROUS_GOODS as IS_DANGEROUS_GOODS,
		BOL.COMPLIANCE_CHECK_PASSED as COMPLIANCE_CHECK_PASSED,
		BOL.FRAUD_CHECK_PASSED as FRAUD_CHECK_PASSED,
		PORT_LOAD.LOADING_PORT_NAME as PORT_NAME with synonyms=('origin port name','port of loading name'),
		PORT_LOAD.LOADING_COUNTRY as COUNTRY with synonyms=('origin country'),
		PORT_DISCHARGE.DISCHARGE_PORT_NAME as PORT_NAME with synonyms=('destination port name','port of discharge name'),
		PORT_DISCHARGE.DISCHARGE_COUNTRY as COUNTRY with synonyms=('destination country'),
		VESSEL.VESSEL_TYPE as VESSEL_TYPE,
		VESSEL.OPERATOR_NAME as OPERATOR_NAME,
		VESSEL.FLAG as FLAG,
		HS.COMMODITY_DESCRIPTION as DESCRIPTION,
		HS.COMMODITY_CATEGORY as CATEGORY,
		HS.HS_IS_DANGEROUS_GOODS as IS_DANGEROUS_GOODS
	)
	metrics (
		BOL.TOTAL_SHIPMENTS as COUNT(BOL.BL_ID) comment='Total number of shipments / Bills of Lading',
		BOL.TOTAL_REVENUE as SUM(BOL.TOTAL_CHARGES) comment='Total revenue from charges',
		BOL.AVG_GROSS_WEIGHT as AVG(BOL.GROSS_WEIGHT_KGS) comment='Average gross weight in kg',
		PORT_LOAD.TOTAL_PORTS as COUNT(PORT_LOAD.PORT_CODE) comment='Total number of seaports in reference data (query PORT_LOAD alone, filtered by country, to count seaports)',
		VESSEL.TOTAL_VESSELS as COUNT(VESSEL.VESSEL_NAME) comment='Total number of vessels in registry'
	)
	comment='Semantic view for VF Logistics Bill of Lading shipments, seaports, vessels and commodity (HS) codes';
