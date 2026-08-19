# Deploy Fix 3 (chat persistence) + the Streamlit app to a target account

Runbook, không phải prose. Chạy từ trên xuống. Mọi khối `sql` dán vào Snowsight
worksheet; mọi khối `powershell` chạy trong terminal.

**Bối cảnh:** `AYUGBCE-JX50275` chỉ dùng làm tài liệu, không deploy. Script này để chạy
trên **tài khoản đích** (tài khoản sẽ dùng chấm thi).

---

## 0. Điều bắt buộc biết trước

| Sự thật | Hệ quả |
|---|---|
| **`PUT` không chạy được trong Snowsight worksheet** | File Streamlit phải lên stage bằng `snow` CLI, bằng IDE, hoặc bằng `Ingestion → Load files into a Stage`. Đừng mất một giờ để phát hiện điều này |
| `chat_persistence.sql` có `create or replace TABLE CHAT_SESSION` | Chạy lần 2 **sẽ xoá** hội thoại đã lưu. Bước 1 kiểm tra trước khi chạy |
| `CREATE OR REPLACE PROCEDURE` xoá sạch `GRANT USAGE` | File đã có 7 `GRANT` ở cuối. Đừng chạy nửa file rồi dừng |
| `HACKATHON_JUDGE_ROLE` phải tồn tại **trước** khi chạy | Nếu chưa có, các `GRANT` cuối file sẽ lỗi |
| Trang Compliance mới đọc key `status` / `issues` | Nếu `CHECK_COMPLIANCE` trên tài khoản đích là bản cũ (trả `compliant` / `violations`), **mọi kết quả sẽ hiện FAILED**. Xem Bước 5 |

---

## 1. Pre-flight — chạy trước, đọc kết quả trước khi làm gì tiếp

```sql
USE DATABASE MENDIX_APP;
USE SCHEMA AGENTS;

SELECT
  (SELECT COUNT(*) FROM MENDIX_APP.INFORMATION_SCHEMA.TABLES
     WHERE TABLE_SCHEMA='AGENTS' AND TABLE_NAME='CHAT_MESSAGE')      AS HAS_CHAT_MESSAGE,
  (SELECT COUNT(*) FROM MENDIX_APP.INFORMATION_SCHEMA.TABLES
     WHERE TABLE_SCHEMA='AGENTS' AND TABLE_NAME='CHAT_SESSION')      AS HAS_CHAT_SESSION,
  (SELECT COUNT(*) FROM MENDIX_APP.INFORMATION_SCHEMA.PROCEDURES
     WHERE PROCEDURE_SCHEMA='AGENTS' AND PROCEDURE_NAME LIKE 'CHAT_%') AS CHAT_PROCS,
  (SELECT COUNT(*) FROM SNOWFLAKE.ACCOUNT_USAGE.ROLES
     WHERE NAME='HACKATHON_JUDGE_ROLE' AND DELETED_ON IS NULL)       AS HAS_JUDGE_ROLE;
```

**Cách đọc kết quả:**

| Kết quả | Nghĩa là | Làm gì |
|---|---|---|
| `HAS_CHAT_MESSAGE = 0` | Fix 3 chưa deploy | Đi tiếp Bước 2 |
| `HAS_CHAT_MESSAGE = 1` và có dữ liệu | Fix 3 **đã** deploy | **DỪNG.** Chạy lại sẽ xoá hội thoại. Chỉ chạy nếu chấp nhận mất |
| `CHAT_PROCS < 6` | Thiếu procedure | Đi tiếp Bước 2 |
| `HAS_JUDGE_ROLE = 0` | Chưa có role judge | Tạo role trước, nếu không 7 `GRANT` cuối file sẽ lỗi |

Nếu `HAS_CHAT_SESSION = 1`, kiểm luôn nó là bảng nào — bảng analytics cũ hay bảng Fix 3:

```sql
SELECT COLUMN_NAME FROM MENDIX_APP.INFORMATION_SCHEMA.COLUMNS
WHERE TABLE_SCHEMA='AGENTS' AND TABLE_NAME='CHAT_SESSION'
ORDER BY ORDINAL_POSITION;
```

Có cột `TITLE` → là bảng Fix 3. Có `TOKENS_USED` / `MESSAGE_COUNT` mà không có `TITLE`
→ là bảng analytics cũ, ghi đè được (đã kiểm trên AYUGBCE: không view/procedure nào
phụ thuộc vào nó).

---

## 2. Chạy chat_persistence.sql

Mở file và chạy **toàn bộ**, không chạy từng phần:

```
vf-logistics-hackathon/sql/workflows/chat_persistence.sql
```

Nó tạo: `CHAT_SESSION`, `CHAT_SESSION_SEQ`, `CHAT_MESSAGE`, và 6 procedure
`CHAT_SESSION_NEW` · `CHAT_MESSAGE_SAVE` · `CHAT_SESSION_LIST` · `CHAT_SESSION_LOAD` ·
`CHAT_SESSION_DELETE` · `CHAT_SESSION_RENAME`, kèm 7 `GRANT`.

Nếu worksheet không cho chạy nhiều statement một lượt, dùng CLI:

```powershell
$r = 'C:\Users\phuochoa\Mendix\VF_Logistics_Portal-main_2\snowflake-backend'
snow sql -f "$r\vf-logistics-hackathon\sql\workflows\chat_persistence.sql" -c <ten_connection>
```

---

## 3. Kiểm tra SQL đã đúng

```sql
SELECT PROCEDURE_NAME, ARGUMENT_SIGNATURE
FROM MENDIX_APP.INFORMATION_SCHEMA.PROCEDURES
WHERE PROCEDURE_SCHEMA='AGENTS' AND PROCEDURE_NAME LIKE 'CHAT_SESSION%'
   OR (PROCEDURE_SCHEMA='AGENTS' AND PROCEDURE_NAME='CHAT_MESSAGE_SAVE')
ORDER BY 1;
```
Phải ra **6 dòng**.

```sql
-- Vòng đời thật: tạo phiên -> lưu 1 lượt -> đọc lại -> xoá
CALL MENDIX_APP.AGENTS.CHAT_SESSION_NEW('EN');
```
Ghi lại `SESSION_ID` trả về, thay vào `<SID>` bên dưới:

```sql
CALL MENDIX_APP.AGENTS.CHAT_MESSAGE_SAVE(<SID>, 'user', 'deploy smoke test');
CALL MENDIX_APP.AGENTS.CHAT_SESSION_LIST();
CALL MENDIX_APP.AGENTS.CHAT_SESSION_LOAD(<SID>);
CALL MENDIX_APP.AGENTS.CHAT_SESSION_DELETE(<SID>);
```

| Bước | Kỳ vọng |
|---|---|
| `CHAT_SESSION_NEW` | Trả về một `SESSION_ID` số |
| `CHAT_MESSAGE_SAVE` | Thành công, không lỗi |
| `CHAT_SESSION_LIST` | Phiên vừa tạo xuất hiện trong danh sách |
| `CHAT_SESSION_LOAD` | Trả về đúng lượt `'deploy smoke test'` |
| `CHAT_SESSION_DELETE` | Xoá xong; `CHAT_SESSION_LIST` không còn thấy nó |

**Đừng bỏ bước này.** Tạo được bảng không chứng minh procedure chạy được — 6 procedure
đều là `EXECUTE AS OWNER` và có kiểm quyền theo `CURRENT_USER()` bên trong.

---

## 4. Đưa file Streamlit lên stage

`PUT` **không** chạy trong worksheet. Ba cách, chọn một:

**Cách A — snow CLI (nhanh nhất):**
```powershell
$r = 'C:\Users\phuochoa\Mendix\VF_Logistics_Portal-main_2\snowflake-backend\streamlit_app'
$c = '<ten_connection>'
snow stage copy "$r\app.py"          "@MENDIX_APP.AGENTS.STREAMLIT_STAGE"       --overwrite -c $c
snow stage copy "$r\ui.py"           "@MENDIX_APP.AGENTS.STREAMLIT_STAGE"       --overwrite -c $c
snow stage copy "$r\i18n.py"         "@MENDIX_APP.AGENTS.STREAMLIT_STAGE"       --overwrite -c $c
snow stage copy "$r\environment.yml" "@MENDIX_APP.AGENTS.STREAMLIT_STAGE"       --overwrite -c $c
snow stage copy "$r\pages"           "@MENDIX_APP.AGENTS.STREAMLIT_STAGE/pages" --overwrite -c $c
```

**Cách B — Snowsight:** `Ingestion → Load files into a Stage → STREAMLIT_STAGE`.
Nhớ 6 file trang phải vào đúng path `pages/`.

**Cách C — nhờ IDE** chạy `PUT` (IDE có client, worksheet không có).

### Bảng đối chiếu — 10 file, kích thước và MD5 phải khớp tuyệt đối

| File | Bytes | MD5 |
|---|---|---|
| `app.py` | 9.471 | `344d5cfb90ef44d319b0016c0536efbd` |
| `ui.py` | 12.315 | `7892821ae4bd42a95a57fb9bab36c09b` |
| `i18n.py` | 84.731 | `2124032bda6e081e71094b90ab3dc75e` |
| `environment.yml` | 67 | `30937defe8f9052f2eff787fc0e7ffa5` |
| `pages/1_Documents.py` | 21.188 | `fa2d74361a0b6fcb04f1904d217d9e14` |
| `pages/2_Compliance.py` | 7.747 | `bee0ca7783046f9ceed6bec1f4a85731` |
| `pages/3_Fraud_Detection.py` | 9.302 | `59466af0d830e459880fa3ba6661bd04` |
| `pages/4_AI_FinOps.py` | 10.714 | `23fa6e9ea1d150b9cf109dfdcd882b4a` |
| `pages/5_Settings.py` | 1.590 | `569f74a218c16591ae7e7569b9a62f6c` |
| `pages/6_AI_Chat.py` | 23.056 | `37c00474e57934ade558fddd4d7dc1a3` |

Kiểm tra sau khi upload:

```sql
ALTER STAGE MENDIX_APP.AGENTS.STREAMLIT_STAGE REFRESH;
SELECT RELATIVE_PATH, SIZE, MD5
FROM DIRECTORY(@MENDIX_APP.AGENTS.STREAMLIT_STAGE)
ORDER BY RELATIVE_PATH;
```

`ALTER STAGE ... REFRESH` là bắt buộc — không có nó `DIRECTORY()` trả kết quả cũ.

**`ui.py` là file dễ quên nhất.** Cả 6 trang mới đều `import ui`; thiếu nó là toàn bộ
app trắng trang với `ModuleNotFoundError`.

Rồi ép app nạp lại file mới:

```sql
ALTER STREAMLIT MENDIX_APP.AGENTS.VF_LOGISTICS_DASHBOARD SET MAIN_FILE = 'app.py';
```

---

## 5. Cạm bẫy: trang Compliance sẽ hiện FAILED hết nếu bỏ bước này

Trang `2_Compliance.py` mới đọc key `status` và `issues`. Bản cũ của
`CHECK_COMPLIANCE` trả `compliant` và `violations`, nên **mọi kết quả sẽ hiện FAILED**
bất kể đúng sai. Kiểm:

```sql
CALL MENDIX_APP.AGENTS.CHECK_COMPLIANCE(
  (SELECT MIN(BL_ID) FROM MENDIX_APP.AGENTS.BILL_OF_LADING));
```

| Kết quả trả về | Nghĩa | Làm gì |
|---|---|---|
| Có key `status` và `issues` | Bản đã sửa | Xong, không cần làm gì |
| Có key `compliant` / `violations` | **Bản cũ** | Deploy lại 2 procedure từ backup, xem dưới |

Bản đã sửa của `CHECK_COMPLIANCE` và `BATCH_CHECK_COMPLIANCE` nằm trong:

```
backup_2026-08-19/ddl/chunks/60_procedures_1.sql .. 60_procedures_4.sql
```

Tìm đúng 2 statement đó và chạy, rồi backfill:

```sql
CALL MENDIX_APP.AGENTS.BATCH_CHECK_COMPLIANCE(0, 20000);

SELECT COUNT(*) AS TOTAL,
       SUM(IFF(COMPLIANCE_CHECK_PASSED, 1, 0))         AS PASSED,
       SUM(IFF(NOT COMPLIANCE_CHECK_PASSED, 1, 0))     AS FAILED,
       SUM(IFF(COMPLIANCE_CHECK_PASSED IS NULL, 1, 0)) AS NEVER_CHECKED
FROM MENDIX_APP.AGENTS.BILL_OF_LADING;
```
Kỳ vọng: `NEVER_CHECKED = 0`, tỉ lệ fail khoảng **13,5 %**.

Sau khi `CREATE OR REPLACE PROCEDURE`, **re-grant**:

```sql
GRANT USAGE ON PROCEDURE MENDIX_APP.AGENTS.CHECK_COMPLIANCE(NUMBER)
  TO ROLE HACKATHON_JUDGE_ROLE;
GRANT USAGE ON PROCEDURE MENDIX_APP.AGENTS.BATCH_CHECK_COMPLIANCE(NUMBER, NUMBER)
  TO ROLE HACKATHON_JUDGE_ROLE;
```

---

## 6. Kiểm tra cuối bằng chính app

| # | Việc | Kỳ vọng |
|---|---|---|
| 1 | Mở app, bấm qua cả 7 trang | Không trang nào lỗi. Nếu trắng trang → thiếu `ui.py` |
| 2 | Trang AI Chat, hỏi `Top 5 carriers by revenue` | Có bảng kết quả + expander **View generated SQL** |
| 3 | **Nhấn F5 reload cả trang**, mở lại conversation ở sidebar | **Transcript còn nguyên, kèm bảng kết quả.** Đây là bằng chứng duy nhất chứng minh Fix 3 hoạt động |
| 4 | Đổi ngôn ngữ EN → 日本語 → Tiếng Việt | Đổi thật, không rơi về tiếng Việt khi chọn Nhật |
| 5 | Trang Compliance, chạy 1 B/L | Ra `PASS`/`FAIL` thật, không phải FAILED hết |

Bước 3 là bước quan trọng nhất. Không reload thì không phân biệt được chat lưu trong
Snowflake với chat lưu trong `st.session_state`.

---

## 7. Trước khi chạy: gate trên máy local

```powershell
$r = 'C:\Users\phuochoa\Mendix\VF_Logistics_Portal-main_2\snowflake-backend\vf-logistics-hackathon'
$env:PYTHONIOENCODING = 'utf-8'
python "$r\tools\check_ui.py"
python "$r\tools\smoke_load_pages.py"
```

Kỳ vọng: `checked 9 files, 348 translation keys x 3 languages` / `OK - safe to PUT` và
`all 7 pages loaded without raising`. Đừng upload nếu một trong hai fail.

---

## 8. Rollback

| Thứ cần lùi | Cách |
|---|---|
| SQL chat | `DROP TABLE CHAT_MESSAGE; DROP TABLE CHAT_SESSION; DROP SEQUENCE CHAT_SESSION_SEQ;` rồi drop 6 procedure. Không object nào khác phụ thuộc |
| File Streamlit | Upload lại bản cũ, hoặc `ALTER STREAMLIT ... SET MAIN_FILE = 'app.py'` sau khi phục hồi file |
| Compliance | `UPDATE BILL_OF_LADING SET COMPLIANCE_CHECK_PASSED = NULL;` để về trạng thái chưa kiểm |

Không cần rollback nếu Bước 1 báo `HAS_CHAT_MESSAGE = 0`: mọi thứ ở đây là thêm mới,
trừ `CHAT_SESSION` nếu bảng analytics cũ tồn tại.
