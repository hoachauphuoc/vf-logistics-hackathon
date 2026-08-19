#!/usr/bin/env python3
"""Generate the 10 end-to-end test Bills of Lading.

The field values are read from MENDIX_APP.TESTSCRATCH.EXPECTED rather than being
duplicated here. That table was built by running the five validated fields of each
scenario through BL_DOC_ALERT and BL_DOC_CONFIDENCE, so the expected verdict comes
from the rules themselves rather than from someone's reading of the rules, and the
PDFs cannot drift out of step with the assertions.

Layout deliberately mirrors sample_documents/pdf/BL_MAERSK_MAEU2026001_VALID.pdf:
the pipeline OCRs the page and then asks an LLM for JSON, so the label wording is
part of the contract. "B/L Number:", "Vessel Name:", "Container Number:",
"Gross Weight:" and "Date of Issue:" are the five labels the validator depends on.

Usage:
    python vf-logistics-hackathon/tools/make_test_bills.py

Writes to sample_documents/pdf/test_cases/.
"""
from __future__ import annotations

import os
import sys

from fpdf import FPDF
from fpdf.enums import XPos, YPos

REPO = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
OUT_DIR = os.path.join(REPO, "sample_documents", "pdf", "test_cases")

# SCAC prefix -> (legal name, carrier code). Used to dress each document in a
# plausible identity so the LLM sees a realistic form, not a field dump.
CARRIERS = {
    "MAEU": ("MAERSK LINE A/S", "MAERSK", "Esplanaden 50, 1098 Copenhagen K, Denmark"),
    "MSKU": ("MAERSK LINE A/S", "MAERSK", "Esplanaden 50, 1098 Copenhagen K, Denmark"),
    "MSCU": ("MSC MEDITERRANEAN SHIPPING COMPANY S.A.", "MSC", "12-14 Chemin Rieu, 1208 Geneva, Switzerland"),
    "COSU": ("COSCO SHIPPING LINES CO., LTD", "COSCO", "378 Daming Road East, Shanghai, China"),
    "CCLU": ("COSCO SHIPPING LINES CO., LTD", "COSCO", "378 Daming Road East, Shanghai, China"),
    "CBHU": ("COSCO SHIPPING LINES CO., LTD", "COSCO", "378 Daming Road East, Shanghai, China"),
    "HLCU": ("HAPAG-LLOYD AG", "HAPAG_LLOYD", "Ballindamm 25, 20095 Hamburg, Germany"),
    "HLXU": ("HAPAG-LLOYD AG", "HAPAG_LLOYD", "Ballindamm 25, 20095 Hamburg, Germany"),
    "ONEY": ("OCEAN NETWORK EXPRESS PTE. LTD.", "ONE", "7 Straits View, Marina One, Singapore 018936"),
    "ONEU": ("OCEAN NETWORK EXPRESS PTE. LTD.", "ONE", "7 Straits View, Marina One, Singapore 018936"),
    "EGLV": ("EVERGREEN MARINE CORP. (TAIWAN) LTD.", "EVERGREEN", "163 Sec 1 Hsin Nan Road, Luchu, Taoyuan, Taiwan"),
}
FALLBACK = ("GLOBAL CONTAINER LINES LTD", "UNSPECIFIED", "Pier 3, Rotterdam, Netherlands")


def carrier_for(bl, container):
    """Return (legal name, carrier code, address, scac) for the document header.

    The SCAC is the real four-letter prefix taken from the B/L or container number,
    not the first four letters of the carrier code. Printing "SCAC: MAER" for a
    MAEU document puts a wrong identifier on a form whose carrier consistency is
    one of the rules under test.
    """
    for code in (bl, container):
        if code:
            prefix = str(code)[:4].upper()
            prof = CARRIERS.get(prefix)
            if prof:
                return prof[0], prof[1], prof[2], prefix
    return FALLBACK[0], FALLBACK[1], FALLBACK[2], "XXXX"


class BL(FPDF):
    def __init__(self, legal_name, carrier_code, address, scac):
        super().__init__(orientation="P", unit="mm", format="A4")
        self.legal_name = legal_name
        self.carrier_code = carrier_code
        self.address = address
        self.scac = scac
        self.set_auto_page_break(auto=True, margin=18)

    def header(self):
        self.set_font("Helvetica", "B", 19)
        self.cell(0, 10, "BILL OF LADING", align="C", new_x=XPos.LMARGIN, new_y=YPos.NEXT)
        self.set_font("Helvetica", "", 9)
        self.cell(0, 5, "ORIGINAL (1 of 3) - NEGOTIABLE", align="C", new_x=XPos.LMARGIN, new_y=YPos.NEXT)
        self.set_font("Helvetica", "B", 11)
        self.cell(0, 5, self.legal_name, align="C", new_x=XPos.LMARGIN, new_y=YPos.NEXT)
        self.set_font("Helvetica", "", 8)
        self.cell(0, 4, self.address, align="C", new_x=XPos.LMARGIN, new_y=YPos.NEXT)
        self.cell(0, 4, f"SCAC: {self.scac} | CARRIER CODE: {self.carrier_code}", align="C",
                  new_x=XPos.LMARGIN, new_y=YPos.NEXT)
        self.ln(4)

    def footer(self):
        self.set_y(-15)
        self.set_font("Helvetica", "I", 8)
        self.cell(0, 8, f"Page {self.page_no()}", align="C")

    def section(self, title):
        self.set_fill_color(233, 233, 233)
        self.set_font("Helvetica", "B", 9.5)
        self.cell(0, 7, f"  {title}", border=0, fill=True,
                  new_x=XPos.LMARGIN, new_y=YPos.NEXT)
        self.ln(1.5)

    def field(self, label, value):
        # A field with no value is omitted entirely rather than printed empty:
        # the point of the missing-B/L-number case is that the label is absent
        # from the document, which is what makes the LLM return null.
        if value is None or str(value).strip() == "":
            return
        # The value width is computed rather than passed as 0. multi_cell(0) means
        # "extend to the right margin", which after a same-line label cell leaves
        # fpdf2 with no usable width and raises "Not enough horizontal space to
        # render a single character".
        label_w = 52.0
        value_w = self.w - self.l_margin - self.r_margin - label_w
        self.set_font("Helvetica", "B", 9)
        self.cell(label_w, 5.4, f"{label}:", new_x=XPos.RIGHT, new_y=YPos.TOP)
        self.set_font("Helvetica", "", 9)
        self.multi_cell(value_w, 5.4, str(value), new_x=XPos.LMARGIN, new_y=YPos.NEXT)


def fmt_weight(kg):
    """12500.0 -> '12,500'; 24.5 -> '24.5'. Keeps the decimal only when real."""
    kg = float(kg)
    return f"{kg:,.1f}".rstrip("0").rstrip(".") if kg % 1 else f"{int(kg):,}"


def build(row, path):
    bl = row["BL_NUMBER"]
    container = row["CONTAINER_NUMBER"]
    vessel = row["VESSEL_NAME"]
    weight = row["GROSS_WEIGHT_KG"]
    issued = row["DATE_OF_ISSUE"]
    legal, code, addr, scac = carrier_for(bl, container)
    tag = str(bl or container or "DOC")[-6:]

    pdf = BL(legal, code, addr, scac)
    pdf.add_page()

    pdf.section("BOOKING / B/L INFORMATION")
    pdf.field("B/L Number", bl)
    pdf.field("Booking Number", f"BKG-{code[:3]}-{tag}")
    pdf.field("Service Type", "CY/CY (Container Yard to Container Yard)")
    pdf.field("Date of Issue", issued)
    pdf.field("Place of Issue", "Ho Chi Minh City, Vietnam")
    pdf.field("Number of Originals", "THREE (3)")
    pdf.ln(2)

    pdf.section("SHIPPER / EXPORTER")
    pdf.field("Company", "VIETNAM ELECTRONICS CO., LTD")
    pdf.field("Address", "45 Nguyen Hue Street, District 1, Ho Chi Minh City, Vietnam")
    pdf.field("Tax ID", "0312456789")
    pdf.ln(2)

    pdf.section("CONSIGNEE")
    pdf.field("Company", "LA TECH DISTRIBUTION INC.")
    pdf.field("Address", "1200 Harbor Blvd, Long Beach, CA 90802, USA")
    pdf.ln(2)

    pdf.section("NOTIFY PARTY")
    pdf.field("Company", "PACIFIC FREIGHT BROKERS LLC")
    pdf.field("Address", "800 S Figueroa St, Los Angeles, CA 90017, USA")
    pdf.ln(2)

    pdf.section("VESSEL / VOYAGE DETAILS")
    pdf.field("Vessel Name", vessel)
    pdf.field("IMO Number", "9876543")
    pdf.field("Voyage Number", f"{code[:2]}-{tag[-3:]}E")
    pdf.field("Port of Loading", "CAT LAI PORT, HO CHI MINH CITY, VIETNAM (VNSGN)")
    pdf.field("Port of Discharge", "PORT OF LOS ANGELES, USA (USLAX)")
    pdf.field("ETA (Estimated Arrival)", "2026-09-05")
    pdf.ln(2)

    pdf.section("CONTAINER / CARGO DETAILS")
    pdf.field("Container Number", container)
    pdf.field("Container Size/Type", "40 ft High Cube (40HC)")
    pdf.field("Seal Number", f"SL-{tag} (Shipper's Seal)")

    pdf.add_page()
    pdf.section("DESCRIPTION OF GOODS")
    pdf.field("Commodity", "ELECTRONIC COMPONENTS - LAPTOP MOTHERBOARDS")
    pdf.field("HS Code", "8471.30.00")
    pdf.field("Number of Packages", "450 CARTONS")
    pdf.field("Package Type", "CORRUGATED CARTON BOXES")
    pdf.field("Gross Weight", f"{fmt_weight(weight)} KGS")
    pdf.field("Net Weight", f"{fmt_weight(max(float(weight) - 700, 0))} KGS")
    pdf.field("Measurement (Volume)", "55.8 CBM")
    pdf.ln(2)

    pdf.section("FREIGHT & CHARGES")
    pdf.field("Freight Terms", "FREIGHT PREPAID")
    pdf.field("Currency", "USD")
    pdf.field("Ocean Freight", "3,450.00")
    pdf.field("Total Charges", "USD 5,120.00")
    pdf.ln(2)

    pdf.section("REGULATORY & COMPLIANCE")
    pdf.field("Dangerous Goods", "NO")
    pdf.field("Export License", "Not Required")
    pdf.ln(2)

    pdf.section("SHIPPED ON BOARD - CLEAN BILL OF LADING")
    pdf.set_font("Helvetica", "", 8)
    pdf.multi_cell(0, 4.4,
                   "CLEAN ON BOARD: SHIPPED on board the vessel named herein in apparent good "
                   "order and condition the total number of containers or packages indicated in "
                   "this Bill of Lading for carriage to the port of discharge or place of "
                   "delivery as stated herein.")
    pdf.ln(3)
    pdf.set_font("Helvetica", "B", 9)
    pdf.cell(0, 5, f"Signed for the Carrier:    Date: {issued}    Place: Ho Chi Minh City, Vietnam",
             new_x=XPos.LMARGIN, new_y=YPos.NEXT)
    pdf.set_font("Helvetica", "I", 8)
    pdf.cell(0, 5, f"{legal} - As Agent for the Carrier",
             new_x=XPos.LMARGIN, new_y=YPos.NEXT)

    pdf.output(path)


def main() -> int:
    from snowflake.snowpark import Session

    session = Session.builder.configs({
        "connection_name": "dpyxiqz-fn71223",
        "client_store_temporary_credential": False,
    }).create()

    rows = session.sql("""
        SELECT FILE_STEM, SCENARIO, BL_NUMBER, CONTAINER_NUMBER, VESSEL_NAME,
               GROSS_WEIGHT_KG, DATE_OF_ISSUE,
               COALESCE(EXPECTED_ALERT, '(none)') AS EXPECTED_ALERT, EXPECTED_CONFIDENCE
        FROM MENDIX_APP.TESTSCRATCH.EXPECTED
        ORDER BY FILE_STEM
    """).collect()
    session.close()

    if not rows:
        print("EXPECTED table is empty - build it before generating PDFs")
        return 1

    os.makedirs(OUT_DIR, exist_ok=True)
    print(f"writing {len(rows)} documents to {OUT_DIR}\n")
    for r in rows:
        path = os.path.join(OUT_DIR, r["FILE_STEM"])
        build(r, path)
        size = os.path.getsize(path)
        print(f"  {r['FILE_STEM']:38} {size:>6} bytes   "
              f"expect conf={r['EXPECTED_CONFIDENCE']:>3} alert={r['EXPECTED_ALERT']}")
    print(f"\n{len(rows)} documents written")
    return 0


if __name__ == "__main__":
    sys.exit(main())
