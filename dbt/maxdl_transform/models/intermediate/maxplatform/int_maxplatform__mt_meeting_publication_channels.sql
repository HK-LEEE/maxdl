-- 자동생성: maxplatform.mt_meeting_publication_channels Silver (replica: 정제 passthrough, 전체교체)
{{ config(materialized='table') }}
select {{ dbt_utils.star(from=ref('stg_maxplatform__mt_meeting_publication_channels')) }}
from {{ ref('stg_maxplatform__mt_meeting_publication_channels') }}
