-- [샘플] maxplatform 사용자 디멘전 (도메인 확정 전 예시)
{{ config(materialized='table') }}
select id as user_id, name as user_name, email, username,
       is_active, (deleted_at is null) as is_active_record,
       created_at, last_login_at, deleted_at
from {{ ref('int_maxplatform__users') }}
