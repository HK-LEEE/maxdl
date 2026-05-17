-- [샘플] 사이트·상태별 서비스요청 집계 팩트 (도메인 확정 전 예시)
{{ config(materialized='table') }}
select site_id, status,
       count(*) as request_count,
       count_if(is_urgent) as urgent_count,
       count_if(is_periodic) as periodic_count
from {{ ref('int_maxplatform__service_requests') }}
group by site_id, status
