# Demo Video Script — 4 minutes

**VF Logistics · Intelligent Workflow Automation Agent · Team SORA**
Target length **4:00** (240 s). Hard ceiling 4:15 — do not run over.

> Chỉ dẫn sân khấu bằng tiếng Việt. **Lời thoại đọc bằng tiếng Anh** trong khối `>`.
> Con số in **đậm** là đọc trực tiếp từ màn hình, không đọc từ giấy — nếu số trên máy
> khác số trong kịch bản thì đọc theo máy.

---

## Quyết định quan trọng trước khi bấm ghi

Kịch bản này giả định hệ thống **đã restore đủ công việc Refinement Phase**.
Trên `AYUGBCE-JX50275` ở trạng thái hiện tại, ba đoạn **không quay được**:

| Đoạn | Vì sao không quay được trên AYUGBCE |
|---|---|
| Chat có lịch sử (Fix 3) | Không có bảng `CHAT_MESSAGE`, không có `CHAT_SESSION_NEW` |
| Đổi ngôn ngữ EN → 日本語 | `i18n.py` bản cũ (53 KB); chọn Nhật sẽ hiện tiếng Việt |
| Compliance 1.351 fail | `COMPLIANCE_CHECK_PASSED` là NULL trên cả 10.021 dòng |

Nếu buộc phải quay hôm nay trên account này, dùng **§6 Biến thể 4 phút không cần
restore** ở cuối file. Đừng đọc lời thoại về những thứ màn hình không chứng minh được —
giám khảo sẽ mở app và kiểm tra.

---

## 1. Pre-flight (làm xong hết mới bấm ghi)

| # | Việc | Vì sao |
|---|---|---|
| 1 | **Nạp 2 PDF mới lên stage** qua Snowsight: `Ingestion → Load files into a Stage → MENDIX_APP.AGENTS.LOGISTICS_STAGE → path bill_of_lading/`. Dùng `sample_documents/pdf/test_cases/TEST_T01_CLEAN.pdf` và `TEST_T10_MULTI_FAILURE.pdf` | **Rủi ro số 1.** Mọi PDF trên stage đã được xử lý, nên pipeline sẽ trả `processed: 0` và video thành ra chứng minh điều ngược lại. T01 sạch + T10 lỗi nhiều là cặp đối lập đẹp nhất: một cái auto-approve, một cái bị chặn |
| 2 | Bấm qua **cả 7 trang** Streamlit một lượt | Làm ấm `COMPUTE_WH` (auto-suspend 60 s). Lần load đầu chậm vài giây và sẽ lộ trong video |
| 3 | Mở sẵn 1 Snowsight worksheet, **dán trước** 3 câu SQL ở §5 | Không gõ SQL trên camera. Gõ sai một ký tự là phải quay lại |
| 4 | Zoom trình duyệt **110–125 %**, ẩn bookmark bar, đóng tab lạ | Chữ Snowsight nhỏ, ở 1080p không đọc được |
| 5 | Tắt hết thông báo (Zalo, Telegram, mail), đóng cửa sổ có mật khẩu | Bạn sẽ chia sẻ toàn màn hình |
| 6 | Ghi **1920×1080, 30 fps**. Test 10 giây rồi nghe lại | Mic rè phát hiện sau khi quay xong là mất cả buổi |

**Quay theo 6 đoạn rời, không quay một hơi.** Bốn phút liền mạch gần như chắc chắn
phải làm lại nhiều lần; 6 clip ngắn ghép lại vừa nhanh hơn vừa gọn hơn.

---

## 2. Bảng thời lượng

| Đoạn | Thời lượng | Mốc | Nội dung |
|---|---|---|---|
| 1 | 0:20 | 0:00–0:20 | Hook + vấn đề |
| 2 | 1:00 | 0:20–1:20 | PDF → quyết định, chạy thật |
| 3 | 0:40 | 1:20–2:00 | AI thật sự quyết định, không hardcode |
| 4 | 0:40 | 2:00–2:40 | Streamlit là giao diện vận hành duy nhất |
| 5 | 0:50 | 2:40–3:30 | Lỗi tự tìm ra: compliance báo pass giả |
| 6 | 0:30 | 3:30–4:00 | Chat có lịch sử + chốt |

---

## 3. Kịch bản chi tiết

### Đoạn 1 — Hook (0:00–0:20)

**Hình:** slide 1 của deck, hoặc trang chủ Streamlit.

> "A bill of lading arrives as a PDF. Today a human reads it, checks it, and decides
> whether the shipment is safe to clear. At ten thousand shipments that does not
> scale, and compliance becomes the bottleneck.
> This is VF Logistics. One command takes a PDF to an executed decision, and every
> step is auditable."

Ghi chú: **không** giới thiệu tên, không "hôm nay tôi sẽ trình bày". 20 giây đầu quyết
định người xem có xem tiếp hay không.

---

### Đoạn 2 — PDF đến quyết định (0:20–1:20)

**Hình:** Streamlit → trang **Documents**.

1. Chỉ vào 2 metric trên cùng. Đọc số **trên màn hình**:
   > "Two PDFs just landed on the stage that the pipeline has not seen yet."

2. Bấm **Process New PDFs on Stage**.
   > "Under the hood this is Cortex PARSE_DOCUMENT in OCR mode, then Cortex COMPLETE
   > on mistral-large2 pulling structured fields out of the OCR text."

3. **CẮT Ở ĐÂY.** Xử lý mất khoảng **20 giây mỗi tài liệu**. Đừng để 40 giây im lặng
   trong video 4 phút. Cắt cảnh, nối sang lúc đã có kết quả, và nói thật:
   > "That takes about twenty seconds per document."

4. Kết quả `{"processed": 2, "errors": 0}`. Cuộn xuống bảng, chỉ vào 2 dòng mới —
   cột **AI Confidence score** và **Alert**.
   > "The clean document scored high and was approved automatically. The other failed
   > validation and was held for review, with the reason recorded."

5. **Câu quan trọng nhất của cả video** — nói chậm:
   > "That confidence score is not the model grading itself. It comes from six
   > deterministic rules in a SQL function: container format, vessel name, gross
   > weight plausibility, date of issue, B/L number, and carrier consistency. The
   > score is simply how many rules passed. The model writes the explanation. It never
   > decides whether the document is valid."

Vì sao câu này quan trọng: điểm yếu chí tử của mọi demo AI là "làm sao tin được con
số của model". Bạn trả lời trước khi bị hỏi.

---

### Đoạn 3 — AI thật sự quyết định (1:20–2:00)

**Hình:** Snowsight worksheet, câu SQL **Q1** (§5).

> **Số liệu khác nhau theo account — đọc từ màn hình, đừng đọc từ đây.**
>
> | | CLEAR | ESCALATE | BLOCK | Tổng |
> |---|---|---|---|---|
> | `AYUGBCE-JX50275` (hiện tại) | 263 | 42 | 43 | 348 |
> | Sau khi restore backup 19/8 | 270 | 55 | 43 | 368 |

1. Chạy Q1. Kết quả 3 nhóm: **CLEAR / ESCALATE / BLOCK**.
   > "Same workflow, same rubric, three different outcomes — cleared, escalated, and
   > blocked."

   Rồi đọc 3 con số **đang hiện trên màn hình**.

2. Chạy Q2 — một alert bị BLOCK kèm lý do. **Đọc đúng lý do trên màn hình.**
   Ví dụ thật hiện tại: *"Cost per kg is 9.33x the peer median cost per kg."*
   > "Here is why this one was blocked, in the model's own words."

   *(đọc nguyên văn cột `AI_DECISION_REASON`)*

   > "The model was given a quantitative evidence pack — this shipment's cost per kilo
   > against the peer median and the ninety-fifth percentile, plus a live sanctions
   > match count from a Snowflake Marketplace dataset — and it had to justify its call
   > against that evidence."

   Ghi chú: **đừng** thuộc lòng một lý do cụ thể. Dữ liệu thay đổi giữa các lần chạy;
   đọc sai thành ra bịa. Slide 11 của deck có ví dụ "shell-style counterparty names" —
   đó là ví dụ minh hoạ, không phải dòng bạn sẽ thấy.

3. Một câu chốt:
   > "The decision is parsed, stored, and then executed by the workflow. It is not a
   > label we print next to a hardcoded action."

---

### Đoạn 4 — Streamlit là giao diện duy nhất (2:00–2:40)

**Hình:** đi nhanh qua các trang, mỗi trang ~8 giây.

1. **Documents → panel Review & Edit.** Sửa 1 field, bấm **Approve**.
   > "This replaces what used to be an external portal. Everything an operator did
   > there — process, review, correct, approve, reject, post to SAP — is native
   > Streamlit in Snowflake now. Editing a field and approving submits a correction
   > carrying only what changed, diffed against the AI output, so human corrections
   > are captured rather than silently overwriting the model."

2. **Fraud Detection** (~6 s) → **AI FinOps** (~8 s).
   > "And this page reflects real Cortex spend, with token counts measured per call."

3. Đổi ngôn ngữ **EN → 日本語 → Tiếng Việt** ngay trên màn hình (~8 s).
   > "Three languages, three hundred and forty-eight keys each, enforced by a
   > pre-deploy check rather than by eye."

> **Chỉ quay bước 3 nếu đã restore.** Trên bản cũ, chọn 日本語 sẽ hiện tiếng Việt —
> quay vào là tự tố cáo mình.

---

### Đoạn 5 — Lỗi tự tìm ra (2:40–3:30)

Đây là đoạn ăn điểm nhất. **Không có hình đẹp cũng được**, nội dung mạnh hơn hình.

**Hình:** worksheet, câu SQL **Q3**.

> "One more thing, and it is the part I would want a reviewer to see.
> Nobody flagged this. While fixing the feedback we found that the compliance batch
> check evaluated no rules at all. It aggregated a flag that nothing ever set,
> counted null as passed, and returned ten thousand and seventeen shipments passed,
> zero failed — a clean bill of health for shipments that had never been examined.
> Running the rules for real: **one thousand three hundred and fifty-one** of them
> fail. Thirteen and a half percent.
> For a compliance system that is the worst class of defect there is. Not a missing
> feature — a false assurance. It is fixed, backfilled, and the stored flag now agrees
> with a fresh evaluation of the rules on every single row."

Ghi chú: nói bình thường, đừng hạ giọng như thú nhận. Tìm ra lỗi này là **năng lực**,
không phải sai sót.

---

### Đoạn 6 — Chat có lịch sử + chốt (3:30–4:00)

**Hình:** trang **AI Chat**.

1. Hỏi: `Top 5 carriers by revenue`. Mở expander **View generated SQL** (~10 s).
2. **Reload cả trang (F5)**, mở lại conversation từ sidebar — transcript còn nguyên.
   > "History lives in Snowflake, not in session state. It survives a reload, a
   > browser restart, and an app restart. The result tables come back from a stored
   > snapshot rather than by re-running the query, so reopening a conversation costs
   > nothing and can never show different rows than the user originally saw."

3. Chốt (~8 s):
   > "One pipeline, from a PDF on a stage to an executed decision, with a
   > deterministic validator, an auditable trail, and an AI that has to justify every
   > call it makes. Thank you."

> **Chỉ quay đoạn này nếu đã restore.** Không có `CHAT_MESSAGE` thì reload sẽ mất
> transcript và bạn vừa quay đúng cái lỗi mà Fix 3 phải sửa.

---

## 4. Những câu KHÔNG được nói

| Đừng nói | Vì sao |
|---|---|
| "Cortex Agent" | `SHOW AGENTS` không trả về object nào. Giám khảo kiểm tra được |
| "Real-time" | Pipeline chạy theo task 5 phút và Cortex mất ~20 s/tài liệu. Dùng "seconds, not hours" |
| "100% accuracy" | Bộ test là 10 tài liệu tự sinh. Nói "ten out of ten on our test set" |
| "Fully autonomous" | Có backpressure và ngưỡng human-review. Nói "autonomous within limits it enforces itself" |
| Con số không đọc từ màn hình | Nếu máy hiện số khác, cả video mất tin cậy |
| Một lý do BLOCK học thuộc từ trước | `AI_DECISION_REASON` thay đổi theo dữ liệu. Đọc dòng đang hiện, không đọc dòng đã thuộc |

---

## 5. SQL dán sẵn vào worksheet

```sql
-- Q1  AI decisions are differentiated, not a single hardcoded branch
SELECT AI_RECOMMENDED_ACTION AS DECISION, COUNT(*) AS ALERTS
FROM MENDIX_APP.AGENTS.FRAUD_ALERT
WHERE AI_RECOMMENDED_ACTION IS NOT NULL
GROUP BY 1 ORDER BY 2 DESC;
```

```sql
-- Q2  one blocked alert, with the reason the model recorded
-- Đọc cột REASON nguyên văn trên màn hình. Lý do thay đổi theo dữ liệu.
SELECT ALERT_ID, ALERT_TYPE, SEVERITY,
       AI_RECOMMENDED_ACTION, AI_DECISION_REASON
FROM MENDIX_APP.AGENTS.FRAUD_ALERT
WHERE AI_RECOMMENDED_ACTION = 'BLOCK'
ORDER BY DETECTED_AT DESC NULLS LAST
LIMIT 1;
```

```sql
-- Q3  the compliance defect, stated as data
SELECT COUNT(*) AS TOTAL_SHIPMENTS,
       SUM(IFF(COMPLIANCE_CHECK_PASSED, 1, 0))     AS PASSED,
       SUM(IFF(NOT COMPLIANCE_CHECK_PASSED, 1, 0)) AS FAILED,
       SUM(IFF(COMPLIANCE_CHECK_PASSED IS NULL, 1, 0)) AS NEVER_CHECKED,
       ROUND(100 * SUM(IFF(NOT COMPLIANCE_CHECK_PASSED, 1, 0)) / COUNT(*), 1)
           AS FAIL_PCT
FROM MENDIX_APP.AGENTS.BILL_OF_LADING;
```

**Cột là `AI_RECOMMENDED_ACTION`, không phải `AI_DECISION`.** Deck từng ghi sai tên này;
gõ `AI_DECISION` sẽ nhận `invalid identifier` ngay trên camera.

Trước khi quay, chạy cả 3 câu một lượt và **đối chiếu số với lời thoại**. Nếu Q3 trả
`NEVER_CHECKED = 10021` thì hệ thống chưa restore → bỏ Đoạn 5, dùng §6.

---

## 6. Biến thể 4 phút KHÔNG cần restore

Quay được ngay trên `AYUGBCE-JX50275`. Bỏ Đoạn 5 và Đoạn 6, giữ nguyên Đoạn 1–4 và
phân bổ lại thời gian:

| Đoạn | Thời lượng | Nội dung |
|---|---|---|
| 1 | 0:20 | Hook (không đổi) |
| 2 | 1:20 | PDF → quyết định. Chậm lại, xử lý **2** PDF, soi kỹ bảng extraction và 6 rule validation |
| 3 | 1:00 | AI quyết định. Thêm Q2 cho một alert `ESCALATE` để đối chiếu với `BLOCK` |
| 4 | 1:00 | Streamlit — **bỏ bước đổi ngôn ngữ**. Thêm trang Fraud Detection và audit trail (`WORKFLOW_AUDIT_LOG`) |
| 5 | 0:20 | Chốt: một pipeline, validator tất định, audit đầy đủ |

Trong biến thể này **không nói** về compliance, về chat có lịch sử, về 3 ngôn ngữ, và
không nói "348 keys". Bốn phút vẫn đủ mạnh mà không có câu nào sai.

---

## 7. Sau khi quay

1. Xem lại **có tiếng**, và tự hỏi từng con số: màn hình có chứng minh không?
2. Cắt mọi khoảng chờ > 2 giây. Chỗ nào cắt vì Cortex chạy lâu thì đã nói rõ trong
   lời thoại — đừng cắt lặng lẽ để trông như nhanh hơn thực tế.
3. Kiểm tra ở 1080p rằng chữ Snowsight **đọc được**. Không đọc được thì zoom và quay lại
   đúng đoạn đó.
4. Xuất **MP4 H.264**, mục tiêu dưới 100 MB.
5. Nghe lại toàn bộ một lần với tai nghe trước khi nộp.
