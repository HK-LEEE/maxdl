-- [샘플] 일자·사용자별 로그인 활동 팩트 (도메인 확정 전 예시)
{{ config(materialized='table') }}
select user_id,
       cast(created_at as date) as login_date,
       count(*) as login_attempts,
       count_if(status = 'success') as success_count,
       count_if(status <> 'success') as fail_count
from {{ ref('int_maxplatform__login_history') }}
where user_id is not null
group by user_id, cast(created_at as date)
