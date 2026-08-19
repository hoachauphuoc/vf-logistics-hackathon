# 1-on-1 SME Session — Script (30 minutes)

**Team SORA · Chau Phuoc Hoa · Snowflake CoCo CLI Hackathon, Refinement Phase**
**When:** 20 Aug 2026, 15:30 IST = **17:00 giờ Việt Nam** · Google Meet `https://meet.google.com/adg-wfvd-onq`
**Final submission deadline:** 23 Aug 2026 (3 ngày sau buổi này)

> Cấu trúc và ghi chú sân khấu bằng tiếng Việt. **Câu nói thật để đọc bằng tiếng Anh** in trong khối `>`.
> Đừng đọc nguyên văn — dùng làm phao. Mục tiêu là *họ* nói, không phải mình nói.

---

## 0. Nguyên tắc chi phối cả buổi

30 phút là rất ngắn. Ba điều quyết định buổi này thành công:

1. **Không thuyết trình. Demo.** SME đã đọc submission; họ muốn thấy nó chạy.
2. **Dành ≥ 8 phút cho câu hỏi của họ.** Đây là giá trị thật của buổi 1-on-1 — bạn không mua được feedback này ở đâu khác. Nếu bạn nói hết 30 phút, bạn đã tự làm mình thiệt.
3. **Chủ động nói ra điểm yếu trước khi họ hỏi.** Đây là lợi thế lớn nhất của submission này: bạn tìm ra nhiều lỗi hơn cả những gì evaluator chỉ ra. Sự thẳng thắn đó ăn điểm — che giấu thì mất điểm gấp đôi khi bị phát hiện.

**Câu chuyện xuyên suốt, nếu chỉ được nói một câu:**

> "The three items you flagged were symptoms. Fixing them properly surfaced defects nobody had flagged — including a compliance report that gave 10,017 shipments a clean bill of health without ever examining one of them. Every fix here is verified by a test built to fail."

---

## 1. Pre-flight — làm T-60 phút (BẮT BUỘC)

| # | Việc | Vì sao |
|---|---|---|
| 1 | **Cập nhật mật khẩu judge vào form submission** (`C:\Users\phuochoa\.snowflake\hackathon_judge_password.txt`) | Mật khẩu cũ đã bị thu hồi. Nếu SME thử đăng nhập bằng giá trị trong form, họ **sẽ bị từ chối** và đó là ấn tượng đầu tiên tệ nhất có thể |
| 2 | **Nạp 2 file PDF test lên stage** qua Snowsight: `Ingestion → Load files into a Stage → MENDIX_APP.AGENTS.LOGISTICS_STAGE → path bill_of_lading/`. Dùng `sample_documents/pdf/test_cases/TEST_T09_CARRIER_MISMATCH.pdf` và `TEST_T10_MULTI_FAILURE.pdf` | **Rủi ro demo số 1.** Stage hiện có 15 PDF và **cả 15 đã extract xong**, nên bấm "Process New PDFs" sẽ trả `{"processed":0}` — nhìn như app hỏng. App **không có** `st.file_uploader`; file chỉ vào stage qua Snowsight hoặc `PUT`. Chọn T09/T10 vì chúng *thất bại có chủ ý* → demo được cả validation, không chỉ happy path |
| 3 | Mở sẵn Streamlit app, bấm qua **cả 7 trang** một lượt | Làm ấm warehouse (`COMPUTE_WH` auto-suspend 60s) và ép cache. Lần load đầu sau khi idle chậm vài giây |
| 4 | Mở sẵn các tab: (a) Streamlit app, (b) Snowsight worksheet, (c) GitHub repo, (d) `README.md`, (e) `docs/E2E_PIPELINE_TEST.md` | Không share screen rồi mới đi tìm tab |
| 5 | Tắt thông báo, đóng Zalo/Telegram, đóng mọi cửa sổ có mật khẩu | Bạn sẽ share toàn màn hình |
| 6 | Kiểm tra mic + đường truyền. Có sẵn số điện thoại dial-in dự phòng | 30 phút không chịu được 5 phút sự cố âm thanh |
| 7 | Chuẩn bị **1 ảnh chụp** kết quả demo quan trọng nhất | Nếu app chết live, bạn vẫn còn bằng chứng |

**Câu SQL warm-up dán vào worksheet trước giờ:**
```sql
SELECT COUNT(*) FROM MENDIX_APP.AGENTS.BILL_OF_LADING;
SHOW TASKS IN SCHEMA MENDIX_APP.AGENTS;
```

---

## 2. Kịch bản theo phút

### 00:00 – 01:30 · Mở đầu (ngắn, không kể chuyện đời)

> "Thanks for the time. I'm Hoa, Team SORA. I'll spend about twelve minutes showing the three items you flagged, working — then I'd rather use the rest on your questions, because that's the part I can't get anywhere else. Please interrupt me at any point."

Ghi chú: câu "please interrupt me" rất quan trọng — nó cho phép họ điều khiển buổi họp theo hướng họ quan tâm, và đó luôn là hướng đúng.

### 01:30 – 03:00 · Bối cảnh & phản hồi tổng quát

Chia màn hình: README mục Fix 1 / 2 / 3.

> "You gave three pieces of feedback: ingestion and admin errors, merge the external sandbox portal into native Streamlit, and rebuild the chat with persistent history. All three are done. But I want to be straight with you about something more important: while fixing them I found four defects you had *not* flagged, and two of them were worse than anything in your list."

### 03:00 – 09:00 · DEMO 1: Ingestion (feedback #1) — 6 phút

Đây là phần mạnh nhất. Làm chậm, để họ thấy từng bước.

1. Mở trang **Documents**. Chỉ vào metric: `PDFs on Stage 17 / Extracted Documents 15`.
   > "Two files landed on the stage a moment ago and haven't been processed. Watch the gap close."
2. Bấm **Process New PDFs on Stage**. Mất **~20 giây/file** (1,3s OCR + 15,4s cho `COMPLETE`) → khoảng 40 giây cho 2 file. **Nói trong lúc chờ**, đừng để im lặng:
   > "Under the hood this is Cortex `PARSE_DOCUMENT` in OCR mode, then `COMPLETE` on mistral-large2 to pull structured fields out of the OCR text. Both calls now write to a ledger — I'll come back to why that matters."
3. Kết quả `{"processed":2,"errors":0,"synced":true}`. Cuộn xuống bảng — 2 dòng mới, kèm **Alert** và **AI Confidence score**.
   > "These two documents were chosen because they fail on purpose. One has a carrier code that contradicts the vessel name; the other fails multiple rules at once. The confidence score isn't a model self-assessment — it's `(6 − failed rules) / 6`, computed by a deterministic SQL function. The model narrates; it never decides."

   **Đây là điểm kỹ thuật mạnh nhất của cả submission. Nhấn mạnh.**
4. Nếu còn thời gian: chọn document trong panel **Review & Edit**, sửa 1 field, bấm Approve.
   > "Editing then approving submits a CORRECT action carrying only the changed fields, diffed against the AI output — so human corrections are captured as training signal, not silently overwritten."

**Nói nguyên nhân gốc của lỗi ingestion (quan trọng — evaluator chỉ thấy triệu chứng):**

> "The original error was `SELECT INTO expects exactly 1 returned row`. I first assumed that meant zero rows. I tested it and I was wrong — it fires on *too many*. The real cause was twenty duplicate `ALERT_ID`s: the column was `autoincrement start 800` while seeded data already used those ids, and Snowflake doesn't enforce the primary key. Same trap turned up in two more tables."

### 09:00 – 12:00 · DEMO 2: Streamlit hợp nhất (feedback #2) — 3 phút

Đi nhanh qua các trang, đừng dừng lâu.

1. **Home** — KPI + chart. Bấm đổi ngôn ngữ **EN → 日本語 → Tiếng Việt** ngay trên màn hình.
   > "347 keys across three languages. Before this, 28 inline conditionals only had English and Vietnamese branches — selecting Japanese silently fell through to Vietnamese. A Japanese reviewer would have seen Vietnamese text and we'd never have known."
2. **Compliance**, **Fraud Detection**, **AI FinOps** — mỗi trang ~20 giây.
3. Chỉ vào **AI FinOps**:
   > "This page was understating real spend by an order of magnitude, because extraction never logged its Cortex calls. It does now, with real token counts from `COUNT_TOKENS`."

> "Mendix is gone as an interface. Everything an operator did in the external portal — process, review, approve, reject, post to SAP — is native Streamlit in Snowflake now."

### 12:00 – 15:00 · DEMO 3: Chat có lịch sử (feedback #3) — 3 phút

1. Mở **AI Chat**. Hỏi một câu: `Top 5 carriers by revenue`.
2. Mở expander **View generated SQL**.
3. **Reload cả trang** (F5) → mở lại conversation từ sidebar → transcript còn nguyên, kèm cả bảng kết quả.
   > "History is in Snowflake, not session state — it survives a reload, a browser restart, and an app restart. The result tables are restored from a stored JSON snapshot rather than by re-running the SQL, so there's no extra warehouse cost and no risk of showing different rows than the user originally saw."
4. Nói luôn hai điểm kiến trúc:
   > "Conversations are scoped per `CURRENT_USER()` and enforced inside owner-rights procedures, so one evaluator cannot read or delete another's history — that's tested, not asserted. And a read-only evaluator role needs no INSERT grant anywhere, because all six persistence paths are `EXECUTE AS OWNER`."

### 15:00 – 20:00 · Phần ăn điểm nhất: lỗi tự tìm ra — 5 phút

Không demo, chỉ kể. Nói gọn, có số.

> "Four things nobody flagged:
>
> **One — a false assurance.** `BATCH_CHECK_COMPLIANCE` evaluated no rules at all. It aggregated a flag that nothing ever set, counted NULL as passed, and returned `{"failed":0,"passed":10017}`. A clean bill of health for ten thousand shipments never examined. Running the rules for real: **1,351 of them — 13.5% — fail.** For a compliance submission that's the most serious class of defect available: not a missing feature, a false statement.
>
> **Two — the fraud detector had switched itself off permanently.** Its backpressure gate counted every open alert ever raised, with no time bound. That number only grows, so the first time the backlog crossed the limit the detector latched shut forever and every run reported `throttled: true` and added nothing. My own end-to-end test read that as 'backpressure working correctly' — that's exactly how this class of bug hides. The queue is a 7-day rolling window now.
>
> **Three — a saturated queue still blinded HIGH-severity detection.** The gate wrapped all five rules, so when it tripped it suppressed every severity. A backlog of MEDIUM alerts could hide a HIGH-severity fraud. Severity-aware now: HIGH rules always run.
>
> **Four — the same unenforced-primary-key trap in three separate tables**, and it taught me that the fix I'd used the first time was wrong. `noorder` autoincrement allocates ids from non-monotonic cached ranges — I measured two consecutive inserts receiving 313 then 651 — so 'burning the counter forward' can't work. They're sequence-backed now."

**Nếu chỉ được kể một cái: kể cái số một.** Nó là cái duy nhất mà một reviewer sẽ nhớ.

**Một câu về phương pháp — nói nếu có 20 giây:**
> "I stopped trusting green results. When a fix's obvious test passed, I reintroduced the bug to confirm the test could actually fail. That caught two cases where the test proved nothing."

### 20:00 – 28:00 · CÂU HỎI CỦA SME — 8 phút

**Đây là phần quan trọng nhất. Không được cắt ngắn để nói thêm.**

> "That's what I have. What would you push on?"

Rồi **im lặng**. Đừng lấp khoảng lặng.

Nếu họ không hỏi gì, mồi bằng câu hỏi của bạn (mục 4 bên dưới).

### 28:00 – 30:00 · Chốt

> "Three asks, quickly: is there anything in what you've seen that you'd consider a blocker for the final submission on the 23rd? Is there anything you'd want me to *remove* rather than add? And is there a Snowflake capability I should be using that I'm clearly not?"

> "I'll send a short written summary of what you flagged, so nothing gets lost. Thank you."

---

## 3. Chủ động khai báo hạn chế (nói trước khi bị hỏi)

Nếu có khoảng trống, hoặc nếu họ hỏi "what's not working" — trả lời **ngay, không quanh co**:

> "Five things I know about and haven't fixed:
> - The SiS runtime is **Streamlit 1.22**, so there's no `st.chat_message` and no `st.fragment`. The chat is built from `text_input` + `markdown`, and the page jumps to top on interaction. That's a runtime limitation, not a design choice.
> - `SYNC_EXTRACTED_TO_BILL_OF_LADING` doesn't deduplicate. The normal pipeline never deletes, so it's a robustness gap rather than a live bug — but it *is* a gap.
> - `AI_ANOMALY_REPORT` matches alert ids with a `LIKE '%'||ALERT_ID||'%'`, which is fuzzy and will mismatch at scale.
> - One orphaned `FRAUD_ALERT` points at a `BL_ID` that doesn't exist. I left it rather than repointing it at a real shipment, which would have invented a business fact.
> - `ALERT_TYPE` carries both `DUPLICATE_BL` and `DUPLICATE_BL_NUMBER` for the same condition — a pre-existing enum split I didn't consolidate, to keep the change reviewable."

Ghi chú: câu cuối của mỗi gạch đầu dòng là **lý do**, không phải lời xin lỗi. "Tôi biết, tôi đã cân nhắc, đây là lý do" mạnh hơn "tôi chưa kịp làm" rất nhiều.

---

## 4. Câu hỏi để HỎI SME (chuẩn bị sẵn 6, dùng 2–3)

Xếp theo giá trị giảm dần:

1. **"If you were scoring this, where would you dock the most points?"** — câu hỏi có giá trị nhất trong cả buổi.
2. "The compliance defect was a false pass on 10,017 rows. Is there a Snowflake-native guardrail — a DMF, a constraint pattern — that would have caught 'this aggregate is summarising a column nothing ever writes'?"
3. "Snowflake doesn't enforce primary keys, and that cost me three separate bugs. What's the accepted production pattern — sequences everywhere, or a DMF asserting uniqueness on a schedule?"
4. "Is a 7-day rolling window the right shape for alert backpressure, or is there a standard approach I'm reinventing?"
5. "Is there anything in the judging criteria that my submission reads as ignoring?"
6. "Is the SiS 1.22 runtime version fixed, or is there a path to a newer Streamlit that I've missed?"

---

## 5. Phương án dự phòng khi sự cố

| Sự cố | Xử lý |
|---|---|
| App không load / trắng trang | Đừng debug live. Chuyển sang Snowsight worksheet và demo bằng SQL: `CALL PROCESS_BL_DOCUMENTS();` rồi `SELECT * FROM BILL_OF_LADING_EXTRACTED ORDER BY PROCESSED_AT DESC;`. Nói: *"Let me show you the same thing at the data layer."* |
| `Process New PDFs` trả `{"processed":0}` | Nghĩa là pre-flight bước 2 chưa làm hoặc file đã bị xử lý ở lần chạy thử. Chuyển sang bảng Extracted Documents nói về **kết quả** thay vì quá trình, và mở `docs/E2E_PIPELINE_TEST.md` (10/10 PASS, 50/50 field khớp tuyệt đối) |
| Cortex chậm / timeout | *"That's a live model call — let me show you the logged latency from a previous run instead."* Mở trang AI FinOps |
| Mất mạng | Dial-in bằng điện thoại, nói tiếp không cần màn hình. Kịch bản mục 15:00–20:00 hoàn toàn không cần demo |
| Hỏi câu bạn không biết | **"I don't know — let me check and send it to you."** Không đoán. Đoán sai trước SME tệ hơn thừa nhận không biết rất nhiều |

---

## 6. Bản nén 10 phút (nếu họ đến muộn hoặc bị cắt giờ)

Bỏ hết, giữ đúng 4 mảnh:

1. (1 phút) Ba feedback đã xong.
2. (3 phút) Demo **chỉ** trang Documents: bấm Process → 2 file mới → chỉ vào Alert + Confidence score, nói "deterministic function decides, model only narrates".
3. (2 phút) Kể **duy nhất** lỗi compliance false-pass 10,017 / 1,351 fail.
4. (4 phút) "Where would you dock the most points?" — rồi im lặng nghe.

---

## 7. Số liệu cần nhớ (đọc lại 5 phút trước giờ)

| Hạng mục | Số |
|---|---|
| B/L trong hệ thống | **10.017** |
| Compliance sau backfill | **8.666 pass / 1.351 fail / 0 unchecked** (13,5% fail) |
| Trước khi sửa, batch check báo | `{"failed":0,"passed":10017}` — **sai hoàn toàn** |
| E2E test | **10/10 PASS**, 50/50 field trích xuất khớp tuyệt đối |
| Khôi phục sau test | 33/33 row count, 32/33 hash khớp (1 lệch do `CURRENT_TIMESTAMP()` theo thiết kế) |
| i18n | **348 key × 3 ngôn ngữ**, 0 điều kiện ngôn ngữ inline |
| Object | 34 table · 11 view · 52 procedure · 10 function · **7 task · 7 stream (1:1)** · 3 dynamic table |
| Quyền judge | 102 → **104 grant**, verified dưới `USE SECONDARY ROLES NONE` |
| Chi phí compliance: row-by-row vs set-based | 3,6 credit vs **0,000087 credit** — rẻ hơn ~41.000 lần |
| Latency 1 document | ~20 giây (OCR 1,3s + `COMPLETE` 15,4s) |
| Token 1 lần extract | 1.082 in + 413 out = **1.495** |
| Alert trùng id đã sửa | 20 `ALERT_ID` · 69 `CALL_ID` · 66 `LOG_ID` |
| Fraud queue: lifetime vs 7 ngày | 106 vs **47** (limit 100) |
| Model | `mistral-large2` |
| 6 rule validation | BlNumber · ContainerNumber · VesselName · GrossWeightKg · DateOfIssue · CarrierMismatch |

---

## 8. Sau buổi họp (làm trong 2 giờ, đừng để nguội)

1. Viết lại **mọi** điều SME nói, kể cả câu nói qua — trước khi quên.
2. Phân loại: (a) sửa được trước 23/8, (b) không kịp → ghi vào README như hạn chế đã biết kèm lý do.
3. Gửi email cảm ơn kèm bản tóm tắt những gì họ nêu. Ngắn. Điều này chứng minh bạn đã nghe.
4. Với mỗi thứ nhóm (a): sửa → **kiểm chứng bằng test có thể fail** → cập nhật README → commit.
5. Kiểm tra lại lần cuối rằng mật khẩu judge trong form là mật khẩu đang dùng thật.
