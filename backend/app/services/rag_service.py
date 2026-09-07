from __future__ import annotations

import time
from datetime import datetime, timedelta, timezone
from email.utils import parsedate_to_datetime
from pathlib import Path
from uuid import uuid4

from sqlalchemy import and_, or_, select, text, update
from sqlalchemy.ext.asyncio import AsyncSession

from app.core.config import Settings
from app.models.rag import (
    RagChunk,
    RagEmbeddingCache,
    RagIngestJob,
    RagPipelineDecision,
    RagRetrievalTrace,
    RagSource,
)
from app.services.rag_index_service import RAGIndexError, RAGIndexService
from app.services.rag_pipeline import (
    CHUNKER_VERSION,
    NORMALIZATION_VERSION,
    ChunkPlan,
    ParsedDocument,
    RAGChunkPlanner,
    RAGDecisionPolicy,
    RAGDocumentParser,
    SourceMetadata,
    build_index_payload_hash,
    estimate_token_count,
    hash_text,
    normalize_text,
    origin_type_for_path,
    split_over_max,
)
from app.services.rag_source_acquisition import FetchedUrlContent, RAGUrlFetcher
from app.services.rag_trace_privacy import (
    RetrievalQueryAudit,
    build_retrieval_query_audit,
    decision_query_context,
)

try:
    from google import genai
except ImportError:  # pragma: no cover - local CLI help can run before deps are installed
    genai = None  # type: ignore[assignment]


class RAGService:
    def __init__(self, db: AsyncSession, settings: Settings):
        self.db = db
        self.settings = settings
        self.client = genai.Client(api_key=settings.GEMINI_API_KEY) if genai is not None else None
        self.index_service = RAGIndexService(settings)
        self.parser = RAGDocumentParser()
        self.url_fetcher = RAGUrlFetcher(settings)
        self.chunk_planner = RAGChunkPlanner()
        self.decision_policy = RAGDecisionPolicy()

    async def get_embedding(self, text_value: str) -> list[float]:
        normalized = text_value.strip()
        if not normalized:
            raise ValueError("Text for embedding must not be empty")
        if self.client is None:
            raise ValueError("google-genai is required for embedding generation")

        embedding_model = self._embedding_model_name()
        result = await self.client.aio.models.embed_content(
            model=embedding_model,
            contents=normalized,
        )
        embeddings = result.embeddings or []
        if not embeddings or embeddings[0].values is None:
            raise ValueError("Embedding response did not include values")
        return [float(value) for value in embeddings[0].values]

    async def search(
        self,
        query: str,
        category: str | None = None,
        top_k: int = 3,
        *,
        user_id: int | None = None,
        request_type: str = "unknown",
        request_id: int | None = None,
        trace_group_id: str | None = None,
    ) -> list[dict]:
        normalized_query = query.strip()
        if not normalized_query:
            return []
        query_audit = build_retrieval_query_audit(
            normalized_query,
            settings=self.settings,
            request_type=request_type,
            category=category,
        )

        retrieval_started = time.perf_counter()
        safe_top_k = max(1, top_k)
        group_id = trace_group_id or str(uuid4())
        embedding_started = time.perf_counter()
        try:
            query_embedding = await self.get_embedding(normalized_query)
        except Exception as exc:
            embedding_latency_ms = int((time.perf_counter() - embedding_started) * 1000)
            opensearch_available = True
            backend_search_started = time.perf_counter()
            try:
                documents = await self._search_opensearch_keyword(normalized_query, category, safe_top_k)
            except RAGIndexError:
                documents = []
                opensearch_available = False
            backend_search_latency_ms = int((time.perf_counter() - backend_search_started) * 1000)
            retrieval_core_latency_ms = int((time.perf_counter() - retrieval_started) * 1000)
            search_backend = "opensearch_keyword_fallback"
            search_mode = "keyword"
            await self._save_pipeline_decision(
                self.decision_policy.embedding_keyword_fallback(
                    query_context=decision_query_context(query_audit),
                    category=category,
                    top_k=safe_top_k,
                    error_type=type(exc).__name__,
                    result_count=len(documents),
                    opensearch_available=opensearch_available,
                )
            )
        else:
            embedding_latency_ms = int((time.perf_counter() - embedding_started) * 1000)
            backend_search_started = time.perf_counter()
            try:
                documents = await self._search_opensearch(normalized_query, query_embedding, category, safe_top_k)
                search_backend = "opensearch"
                search_mode = "hybrid"
            except RAGIndexError as exc:
                documents = await self._search_pgvector(normalized_query, query_embedding, category, safe_top_k)
                search_backend = "pgvector_fallback"
                search_mode = "vector"
                backend_search_latency_ms = int((time.perf_counter() - backend_search_started) * 1000)
                retrieval_core_latency_ms = int((time.perf_counter() - retrieval_started) * 1000)
                await self._save_pipeline_decision(
                    self.decision_policy.opensearch_fallback(
                        query_context=decision_query_context(query_audit),
                        category=category,
                        top_k=safe_top_k,
                        error_type=type(exc).__name__,
                    )
                )
            else:
                backend_search_latency_ms = int((time.perf_counter() - backend_search_started) * 1000)
                retrieval_core_latency_ms = int((time.perf_counter() - retrieval_started) * 1000)

        for document in documents:
            document["rag_trace_group_id"] = group_id
            document["search_backend"] = search_backend
            document["search_mode"] = search_mode
            document["embedding_latency_ms"] = embedding_latency_ms
            document["backend_search_latency_ms"] = backend_search_latency_ms
            document["retrieval_core_latency_ms"] = retrieval_core_latency_ms

        if user_id is not None:
            await self._save_retrieval_traces(
                documents=documents,
                user_id=user_id,
                request_type=request_type,
                request_id=request_id,
                trace_group_id=group_id,
                query_audit=query_audit,
                category=category,
                top_k=safe_top_k,
                search_backend=search_backend,
                search_mode=search_mode,
            )
        else:
            await self.db.commit()

        return documents

    async def ingest_document(
        self,
        title: str,
        content: str,
        category: str,
        source: str = "",
        *,
        tags: list[str] | None = None,
        source_type: str = "internal_policy",
        source_grade: str = "B",
        license_value: str | None = "internal-summary",
        language: str = "ko",
        author_or_org: str | None = None,
        parser_type: str = "text",
    ) -> int:
        parsed = self.parser.parse_content(
            content,
            title=title,
            source_uri=source or None,
            parser_type=parser_type,
        )
        result = await self._ingest_parsed_document(
            parsed=parsed,
            title=title,
            category=category,
            source_url=source or None,
            origin_type="manual_text",
            origin_uri=source or None,
            tags=self._normalize_tags(tags),
            source_type=source_type,
            source_grade=source_grade,
            license_value=license_value,
            language=language,
            author_or_org=author_or_org,
            refresh_policy="manual",
            existing_source=None,
            force=False,
        )
        return int(result["chunks_active"])

    async def parse_preview(self, file_path: str | Path, *, parser_type: str = "auto") -> dict:
        parsed = self.parser.parse_file(file_path, parser_type=parser_type)
        plans = self._build_chunk_plans(
            parsed,
            source_title=parsed.title,
            category="preview",
            tags=[],
            source_grade="B",
            source_version=1,
        )
        return {
            "parser_type": parsed.parser_type,
            "parser_version": parsed.parser_version,
            "parser_confidence": parsed.parser_confidence,
            "content_hash": parsed.content_hash,
            "chunks_total": len(plans),
            "chunks": [
                {
                    "chunk_index": plan.chunk_index,
                    "title": plan.title,
                    "content_hash": plan.content_hash,
                    "anchor_hash": plan.anchor_hash,
                    "chunk_strategy": plan.chunk_strategy,
                    "chunk_anchor": plan.chunk_anchor,
                    "page_number": plan.page_number,
                    "token_count": plan.token_count,
                    "preview": plan.content[:240],
                }
                for plan in plans
            ],
        }

    async def fetch_preview_url(self, url: str, *, title: str | None = None) -> dict[str, object]:
        fetched = await self.url_fetcher.fetch(url)
        parsed = self._parse_fetched_url(fetched, title=title)
        plans = self._build_chunk_plans(
            parsed,
            source_title=parsed.title,
            category="preview",
            tags=[],
            source_grade="A",
            source_version=1,
        )
        parent_sections = self._parent_section_preview(plans)
        return {
            "url": url,
            "final_url": fetched.final_url,
            "content_type": fetched.content_type,
            "http_headers": {
                "etag": fetched.etag,
                "last_modified": fetched.last_modified,
            },
            "raw_content_hash": fetched.raw_content_hash,
            "normalized_content_hash": parsed.content_hash,
            "title": parsed.title,
            "parser_type": parsed.parser_type,
            "parser_version": parsed.parser_version,
            "parser_confidence": parsed.parser_confidence,
            "parent_sections_total": len(parent_sections),
            "child_chunks_total": len(plans),
            "parent_sections": parent_sections[:20],
            "child_chunks": [
                {
                    "chunk_index": plan.chunk_index,
                    "title": plan.title,
                    "content_hash": plan.content_hash,
                    "parent_heading_path": plan.metadata.get("parent_heading_path"),
                    "parent_section_hash": plan.metadata.get("parent_section_hash"),
                    "chunk_strategy": plan.chunk_strategy,
                    "token_count": plan.token_count,
                    "preview": plan.content[:240],
                }
                for plan in plans[:20]
            ],
        }

    async def register_source(
        self,
        *,
        file_path: str | Path,
        title: str | None,
        category: str,
        tags: list[str] | None = None,
        parser_type: str = "auto",
        source_url: str | None = None,
        source_type: str = "file",
        source_grade: str = "B",
        license_value: str | None = "internal-summary",
        language: str = "ko",
        author_or_org: str | None = None,
        refresh_policy: str = "manual",
        refresh_interval_hours: int | None = None,
    ) -> dict[str, object]:
        path = Path(file_path)
        parsed = self.parser.parse_file(path, parser_type=parser_type)
        return await self._ingest_parsed_document(
            parsed=parsed,
            title=title or parsed.title,
            category=category,
            source_url=source_url,
            origin_type=origin_type_for_path(path),
            origin_uri=str(path),
            tags=self._normalize_tags(tags),
            source_type=source_type,
            source_grade=source_grade,
            license_value=license_value,
            language=language,
            author_or_org=author_or_org,
            refresh_policy=refresh_policy,
            refresh_interval_hours=refresh_interval_hours,
            existing_source=None,
            force=False,
        )

    async def register_url(
        self,
        *,
        url: str,
        title: str | None,
        category: str,
        tags: list[str] | None = None,
        source_type: str = "official_guideline",
        source_grade: str = "A",
        license_value: str | None = None,
        language: str = "en",
        author_or_org: str | None = None,
        refresh_policy: str = "scheduled",
        refresh_interval_hours: int | None = 720,
        catalog_key: str | None = None,
        catalog_file: str | None = None,
        force: bool = False,
        force_full_reindex: bool = False,
    ) -> dict[str, object]:
        fetched = await self.url_fetcher.fetch(url)
        parsed = self._parse_fetched_url(
            fetched,
            title=title,
            extra_metadata={"catalog_key": catalog_key, "catalog_file": catalog_file},
        )
        existing_source = await self._find_existing_url_source(url, fetched.final_url)
        return await self._ingest_parsed_document(
            parsed=parsed,
            title=title or parsed.title,
            category=category,
            source_url=fetched.final_url,
            origin_type="url_html",
            origin_uri=url,
            tags=self._normalize_tags(tags),
            source_type=source_type,
            source_grade=source_grade,
            license_value=license_value,
            language=language,
            author_or_org=author_or_org,
            refresh_policy=refresh_policy,
            refresh_interval_hours=refresh_interval_hours,
            existing_source=existing_source,
            force=force,
            force_full_reindex=force_full_reindex,
        )

    async def refresh_source(
        self,
        source_id: int,
        *,
        force: bool = False,
        force_full_reindex: bool = False,
    ) -> dict[str, object]:
        source = await self.db.get(RagSource, source_id)
        if source is None:
            return {"status": "not_found", "source_id": source_id}
        if not source.origin_uri:
            return {"status": "failed", "source_id": source_id, "error": "SOURCE_ORIGIN_URI_MISSING"}

        if source.origin_type == "url_html" or source.parser_type == "html":
            fetched = await self.url_fetcher.fetch(source.origin_uri)
            parsed = self._parse_fetched_url(fetched, title=source.title)
            source_url = fetched.final_url
        else:
            parsed = self.parser.parse_file(source.origin_uri, parser_type=source.parser_type or "auto")
            source_url = source.source_url
        return await self._ingest_parsed_document(
            parsed=parsed,
            title=source.title,
            category=source.category,
            source_url=source_url,
            origin_type=source.origin_type,
            origin_uri=source.origin_uri,
            tags=list(source.tags or []),
            source_type=source.source_type,
            source_grade=source.source_grade,
            license_value=source.license,
            language=source.language,
            author_or_org=source.author_or_org,
            refresh_policy=source.refresh_policy,
            refresh_interval_hours=source.refresh_interval_hours,
            existing_source=source,
            force=force,
            force_full_reindex=force_full_reindex,
        )

    async def refresh_due(self, *, limit: int = 20) -> list[dict[str, object]]:
        now = datetime.now(timezone.utc)
        stmt = (
            select(RagSource)
            .where(
                RagSource.status == "active",
                RagSource.refresh_policy == "scheduled",
                RagSource.next_refresh_at.is_not(None),
                RagSource.next_refresh_at <= now,
            )
            .order_by(RagSource.next_refresh_at.asc())
            .limit(limit)
        )
        sources = (await self.db.execute(stmt)).scalars().all()
        results: list[dict[str, object]] = []
        for source in sources:
            results.append(await self.refresh_source(source.id))
        return results

    async def list_decisions(self, *, job_id: int | None = None, limit: int = 20) -> list[dict[str, object]]:
        stmt = select(RagPipelineDecision).order_by(RagPipelineDecision.id.desc()).limit(limit)
        if job_id is not None:
            stmt = stmt.where(RagPipelineDecision.job_id == job_id)
        rows = (await self.db.execute(stmt)).scalars().all()
        return [
            {
                "id": row.id,
                "job_id": row.job_id,
                "source_id": row.source_id,
                "decision_type": row.decision_type,
                "policy_version": row.policy_version,
                "selected_action": row.selected_action,
                "risk_level": row.risk_level,
                "reason_code": row.reason_code,
                "context": row.context,
                "tradeoffs": row.tradeoffs,
                "created_at": row.created_at.isoformat() if row.created_at else None,
            }
            for row in rows
        ]

    async def ensure_index(self) -> bool:
        return await self.index_service.ensure_index()

    async def delete_index(self) -> bool:
        return await self.index_service.delete_index()

    async def index_status(self) -> dict[str, object]:
        return await self.index_service.index_status()

    async def reindex(self, source_id: int | None = None) -> dict[str, int]:
        await self.ensure_index()
        stmt = (
            select(RagChunk, RagSource)
            .join(RagSource, RagSource.id == RagChunk.source_id)
            .where(RagChunk.status == "active", RagSource.status == "active")
            .order_by(RagChunk.id.asc())
        )
        if source_id is not None:
            stmt = stmt.where(RagChunk.source_id == source_id)

        rows = (await self.db.execute(stmt)).all()
        indexed = 0
        failed = 0
        skipped = 0
        for chunk, source in rows:
            payload_hash = self._index_payload_hash(chunk, source)
            if chunk.index_status == "indexed" and chunk.index_payload_hash == payload_hash:
                skipped += 1
                continue
            chunk.index_payload_hash = payload_hash
            try:
                await self.index_service.index_chunk(chunk, source)
            except RAGIndexError:
                chunk.index_status = "failed"
                failed += 1
                continue
            chunk.index_status = "indexed"
            chunk.indexed_at = datetime.now(timezone.utc)
            chunk.opensearch_index = self.settings.RAG_OPENSEARCH_INDEX
            chunk.opensearch_document_id = str(chunk.id)
            indexed += 1
        await self.db.commit()
        return {"indexed": indexed, "failed": failed, "skipped": skipped}

    async def archive_source(self, source_id: int) -> dict[str, int]:
        source = await self.db.get(RagSource, source_id)
        if source is None:
            return {"sources": 0, "chunks": 0}

        source.status = "archived"
        source.last_refresh_status = "archived"
        chunks = (
            await self.db.execute(select(RagChunk).where(RagChunk.source_id == source_id))
        ).scalars().all()

        archived_chunks = 0
        for chunk in chunks:
            await self._archive_chunk(chunk)
            archived_chunks += 1
        await self.db.commit()
        return {"sources": 1, "chunks": archived_chunks}

    async def mark_traces_request_id(self, trace_group_id: str | None, request_id: int | None) -> None:
        if not trace_group_id or request_id is None:
            return
        await self.db.execute(
            update(RagRetrievalTrace)
            .where(RagRetrievalTrace.rag_trace_group_id == trace_group_id)
            .values(request_id=request_id)
        )

    async def mark_traces_used_in_response(
        self,
        trace_group_id: str | None,
        chunk_ids: list[int],
    ) -> None:
        if not trace_group_id:
            return
        await self.db.execute(
            update(RagRetrievalTrace)
            .where(RagRetrievalTrace.rag_trace_group_id == trace_group_id)
            .values(used_in_response=False)
        )
        if chunk_ids:
            await self.db.execute(
                update(RagRetrievalTrace)
                .where(
                    RagRetrievalTrace.rag_trace_group_id == trace_group_id,
                    RagRetrievalTrace.chunk_id.in_(chunk_ids),
                )
                .values(used_in_response=True)
            )

    def _parse_fetched_url(
        self,
        fetched: FetchedUrlContent,
        *,
        title: str | None = None,
        extra_metadata: dict[str, object | None] | None = None,
    ) -> ParsedDocument:
        metadata = fetched.metadata()
        if extra_metadata:
            metadata.update({key: value for key, value in extra_metadata.items() if value is not None})
        return self.parser.parse_html(
            fetched.text,
            title=title,
            source_uri=fetched.requested_url,
            source_url=fetched.final_url,
            content_type=fetched.content_type,
            fetch_metadata=metadata,
        )

    async def _find_existing_url_source(self, requested_url: str, final_url: str) -> RagSource | None:
        url_values = list({requested_url, final_url})
        stmt = (
            select(RagSource)
            .where(
                RagSource.status == "active",
                RagSource.origin_type == "url_html",
                or_(RagSource.origin_uri.in_(url_values), RagSource.source_url.in_(url_values)),
            )
            .order_by(RagSource.id.asc())
            .limit(1)
        )
        return (await self.db.execute(stmt)).scalar_one_or_none()

    @staticmethod
    def _parent_section_preview(plans: list[ChunkPlan]) -> list[dict[str, object]]:
        sections: dict[str, dict[str, object]] = {}
        for plan in plans:
            parent_hash = str(plan.metadata.get("parent_section_hash") or "")
            if not parent_hash:
                continue
            record = sections.setdefault(
                parent_hash,
                {
                    "parent_section_hash": parent_hash,
                    "parent_heading_path": plan.metadata.get("parent_heading_path"),
                    "child_chunk_count": 0,
                },
            )
            record["child_chunk_count"] = int(record["child_chunk_count"]) + 1
        return list(sections.values())

    async def _ingest_parsed_document(
        self,
        *,
        parsed: ParsedDocument,
        title: str,
        category: str,
        source_url: str | None,
        origin_type: str,
        origin_uri: str | None,
        tags: list[str],
        source_type: str,
        source_grade: str,
        license_value: str | None,
        language: str,
        author_or_org: str | None,
        refresh_policy: str,
        existing_source: RagSource | None,
        force: bool,
        refresh_interval_hours: int | None = None,
        force_full_reindex: bool = False,
    ) -> dict[str, object]:
        started_at = datetime.now(timezone.utc)
        embedding_model = self._embedding_model_name()
        source_exists = existing_source is not None
        old_chunks = await self._load_active_source_chunks(existing_source.id) if existing_source else []
        next_source_version = (existing_source.version + 1) if existing_source else 1
        plans = self._build_chunk_plans(
            parsed,
            source_title=title,
            category=category,
            tags=tags,
            source_grade=source_grade,
            source_version=next_source_version,
        )
        source_hash_same = bool(existing_source and existing_source.content_hash == parsed.content_hash and not force)
        parser_or_chunker_changed = bool(
            existing_source
            and (
                existing_source.parser_version != parsed.parser_version
                or existing_source.chunker_version != CHUNKER_VERSION
                or existing_source.normalization_version != NORMALIZATION_VERSION
                or self._anchor_lineage_missing(old_chunks, plans)
                or force_full_reindex
            )
        )
        change_ratio = self._change_ratio(old_chunks, plans)
        refresh_context = self._refresh_decision_context(
            existing_source=existing_source,
            old_chunks=old_chunks,
            new_plans=plans,
            parsed=parsed,
        )
        estimated_embedding_count = self._estimate_new_embedding_count(old_chunks, plans)
        estimated_embedding_seconds = (
            estimated_embedding_count * self.settings.RAG_ESTIMATED_EMBEDDING_SECONDS_PER_CHUNK
        )
        decision = self.decision_policy.choose_ingest_action(
            source_exists=source_exists,
            source_hash_same=source_hash_same,
            parser_confidence=parsed.parser_confidence,
            change_ratio=change_ratio,
            parser_or_chunker_changed=parser_or_chunker_changed,
            estimated_embedding_seconds=estimated_embedding_seconds,
            allowed_embedding_seconds=self.settings.RAG_ALLOWED_REEMBEDDING_SECONDS,
            partial_refresh_threshold=self.settings.RAG_PARTIAL_REFRESH_CHANGE_RATIO,
            parser_confidence_threshold=self.settings.RAG_PARSER_CONFIDENCE_THRESHOLD,
            source_grade=source_grade,
            category=category,
            extra_context=refresh_context,
        )

        job = RagIngestJob(
            job_type="refresh" if existing_source else "create",
            status="running",
            requested_by="cli",
            input_hash=parsed.content_hash,
            embedding_model=embedding_model,
            target_index=self.settings.RAG_OPENSEARCH_INDEX,
            chunks_total=len(plans),
            pipeline_stage="policy_decision",
            parser_confidence=parsed.parser_confidence,
            change_ratio=change_ratio,
            estimated_embedding_seconds=estimated_embedding_seconds,
            started_at=started_at,
        )
        if existing_source:
            job.source_id = existing_source.id
        self.db.add(job)
        await self.db.flush()

        if decision.selected_action in {"skip_refresh", "manual_review_required", "defer_reembedding"}:
            await self._save_pipeline_decision(
                decision,
                job_id=job.id,
                source_id=existing_source.id if existing_source else None,
            )
            job.status = "skipped"
            job.pipeline_stage = decision.selected_action
            job.skipped_reason = decision.reason_code
            job.finished_at = datetime.now(timezone.utc)
            job.latency_ms = self._latency_ms(started_at)
            if existing_source:
                existing_source.last_checked_at = datetime.now(timezone.utc)
                existing_source.last_refresh_status = decision.selected_action
            await self.db.commit()
            return {
                "status": job.status,
                "job_id": job.id,
                "source_id": existing_source.id if existing_source else None,
                "decision": decision.selected_action,
                "chunks_active": len(old_chunks),
                "chunks_created": 0,
                "chunks_reused": 0,
            }

        source = existing_source or RagSource(
            title=title,
            source_type=source_type,
            source_url=source_url,
            origin_type=origin_type,
            origin_uri=origin_uri,
            ingest_method="cli",
            source_grade=source_grade,
            license=license_value,
            category=category,
            tags=tags,
            language=language,
            author_or_org=author_or_org,
            status="active",
            version=1,
            content_hash=parsed.content_hash,
        )
        if existing_source is None:
            self.db.add(source)
            await self.db.flush()
            job.source_id = source.id
        else:
            source.version = next_source_version

        await self._save_pipeline_decision(decision, job_id=job.id, source_id=source.id)

        self._apply_source_metadata(
            source,
            parsed=parsed,
            title=title,
            source_type=source_type,
            source_url=source_url,
            origin_type=origin_type,
            origin_uri=origin_uri,
            tags=tags,
            source_grade=source_grade,
            license_value=license_value,
            category=category,
            language=language,
            author_or_org=author_or_org,
            refresh_policy=refresh_policy,
            refresh_interval_hours=refresh_interval_hours,
        )

        created = 0
        reused = 0
        indexed_succeeded = 0
        indexed_failed = 0
        index_skipped = 0
        embedding_reused = 0
        reembedded = 0

        try:
            job.pipeline_stage = "chunk_persist"
            if decision.selected_action == "partial_refresh" and old_chunks:
                old_by_anchor = {chunk.anchor_hash: chunk for chunk in old_chunks}
                new_anchor_hashes = {plan.anchor_hash for plan in plans}
                for plan in plans:
                    existing_chunk = old_by_anchor.get(plan.anchor_hash)
                    if (
                        existing_chunk
                        and existing_chunk.content_hash == plan.content_hash
                        and existing_chunk.embedding_input_hash == plan.embedding_input_hash
                    ):
                        plan_payload_hash = self._index_payload_hash(existing_chunk, source)
                        if existing_chunk.index_status == "indexed" and existing_chunk.index_payload_hash == plan_payload_hash:
                            index_skipped += 1
                        else:
                            existing_chunk.index_payload_hash = plan_payload_hash
                            try:
                                await self.index_service.index_chunk(existing_chunk, source)
                            except RAGIndexError:
                                existing_chunk.index_status = "failed"
                                indexed_failed += 1
                            else:
                                existing_chunk.index_status = "indexed"
                                existing_chunk.indexed_at = datetime.now(timezone.utc)
                                indexed_succeeded += 1
                        reused += 1
                        continue
                    if existing_chunk:
                        await self._archive_chunk(existing_chunk)
                    chunk, was_reused = await self._create_chunk_from_plan(plan, source, tags, category)
                    created += 1
                    embedding_reused += int(was_reused)
                    reembedded += int(not was_reused)
                    if chunk.index_status == "indexed":
                        indexed_succeeded += 1
                    elif chunk.index_status == "failed":
                        indexed_failed += 1

                for old_chunk in old_chunks:
                    if old_chunk.anchor_hash not in new_anchor_hashes:
                        await self._archive_chunk(old_chunk)
            else:
                for old_chunk in old_chunks:
                    await self._archive_chunk(old_chunk)
                for plan in plans:
                    chunk, was_reused = await self._create_chunk_from_plan(plan, source, tags, category)
                    created += 1
                    embedding_reused += int(was_reused)
                    reembedded += int(not was_reused)
                    if chunk.index_status == "indexed":
                        indexed_succeeded += 1
                    elif chunk.index_status == "failed":
                        indexed_failed += 1

            job.pipeline_stage = "finished"
            job.chunks_succeeded = created + reused
            job.indexed_total = created + reused
            job.indexed_succeeded = indexed_succeeded
            job.indexed_failed = indexed_failed
            job.index_skip_count = index_skipped
            job.embedding_reuse_count = embedding_reused + reused
            job.reembedding_count = reembedded
            job.status = "succeeded" if indexed_failed == 0 else "failed"
            if indexed_failed:
                job.error_code = "OPENSEARCH_INDEX_FAILED"
                job.error_message = "Some RAG chunks failed OpenSearch indexing"
            job.finished_at = datetime.now(timezone.utc)
            job.latency_ms = self._latency_ms(started_at)
            source.last_refresh_status = job.status
            await self.db.commit()
        except Exception:
            job.status = "failed"
            job.pipeline_stage = "failed"
            job.chunks_failed = len(plans)
            job.error_code = "INGEST_FAILED"
            job.error_message = "RAG ingest pipeline failed"
            job.finished_at = datetime.now(timezone.utc)
            job.latency_ms = self._latency_ms(started_at)
            await self.db.rollback()
            raise

        return {
            "status": job.status,
            "job_id": job.id,
            "source_id": source.id,
            "decision": decision.selected_action,
            "chunks_active": created + reused,
            "chunks_created": created,
            "chunks_reused": reused,
            "embedding_reuse_count": job.embedding_reuse_count,
            "reembedding_count": job.reembedding_count,
            "index_skip_count": job.index_skip_count,
        }

    async def _create_chunk_from_plan(
        self,
        plan: ChunkPlan,
        source: RagSource,
        tags: list[str],
        category: str,
    ) -> tuple[RagChunk, bool]:
        embedding, reused, cache_id = await self._get_or_create_embedding(plan)
        metadata = dict(plan.metadata)
        metadata["embedding_reuse"] = {"reused": reused, "cache_id": cache_id}
        chunk = RagChunk(
            source_id=source.id,
            chunk_index=plan.chunk_index,
            title=plan.title,
            content=plan.content,
            content_hash=plan.content_hash,
            anchor_hash=plan.anchor_hash,
            embedding_input_hash=plan.embedding_input_hash,
            index_payload_hash=plan.index_payload_hash,
            category=category,
            tags=tags,
            embedding=embedding,
            embedding_model=self._embedding_model_name(),
            embedding_dim=len(embedding),
            opensearch_index=self.settings.RAG_OPENSEARCH_INDEX,
            index_status="pending",
            token_count=plan.token_count,
            source_version=source.version,
            chunk_strategy=plan.chunk_strategy,
            chunk_anchor=plan.chunk_anchor,
            page_number=plan.page_number,
            metadata_=metadata,
            status="active",
            version=1,
        )
        self.db.add(chunk)
        await self.db.flush()
        chunk.opensearch_document_id = str(chunk.id)
        try:
            await self.index_service.index_chunk(chunk, source)
        except RAGIndexError:
            chunk.index_status = "failed"
        else:
            chunk.index_status = "indexed"
            chunk.indexed_at = datetime.now(timezone.utc)
        return chunk, reused

    async def _get_or_create_embedding(self, plan: ChunkPlan) -> tuple[list[float], bool, int | None]:
        embedding_model = self._embedding_model_name()
        stmt = select(RagEmbeddingCache).where(
            RagEmbeddingCache.embedding_input_hash == plan.embedding_input_hash,
            RagEmbeddingCache.embedding_model == embedding_model,
            RagEmbeddingCache.embedding_dim == 3072,
            RagEmbeddingCache.normalization_version == NORMALIZATION_VERSION,
        )
        cache = (await self.db.execute(stmt)).scalar_one_or_none()
        now = datetime.now(timezone.utc)
        if cache is not None:
            cache.usage_count += 1
            cache.last_used_at = now
            return [float(value) for value in cache.embedding], True, cache.id

        embedding = await self.get_embedding(plan.content)
        cache = RagEmbeddingCache(
            embedding_input_hash=plan.embedding_input_hash,
            content_hash=plan.content_hash,
            embedding_model=embedding_model,
            embedding_dim=len(embedding),
            normalization_version=NORMALIZATION_VERSION,
            embedding=embedding,
            usage_count=1,
            last_used_at=now,
        )
        self.db.add(cache)
        await self.db.flush()
        return embedding, False, cache.id

    async def _archive_chunk(self, chunk: RagChunk) -> None:
        chunk.status = "archived"
        chunk.index_status = "deleted"
        try:
            await self.index_service.delete_chunk(chunk.id)
        except RAGIndexError:
            pass

    def _apply_source_metadata(
        self,
        source: RagSource,
        *,
        parsed: ParsedDocument,
        title: str,
        source_type: str,
        source_url: str | None,
        origin_type: str,
        origin_uri: str | None,
        tags: list[str],
        source_grade: str,
        license_value: str | None,
        category: str,
        language: str,
        author_or_org: str | None,
        refresh_policy: str,
        refresh_interval_hours: int | None,
    ) -> None:
        now = datetime.now(timezone.utc)
        source.title = title
        source.source_type = source_type
        source.source_url = source_url
        source.origin_type = origin_type
        source.origin_uri = origin_uri
        source.ingest_method = "cli"
        source.parser_type = parsed.parser_type
        source.parser_version = parsed.parser_version
        source.chunk_strategy = self._strategy_for_parser(parsed.parser_type)
        source.chunker_version = CHUNKER_VERSION
        source.normalization_version = NORMALIZATION_VERSION
        source.refresh_policy = refresh_policy
        source.refresh_interval_hours = refresh_interval_hours
        source.next_refresh_at = self._next_refresh_at(refresh_policy, refresh_interval_hours, now)
        source.last_checked_at = now
        source.source_grade = source_grade
        source.license = license_value
        source.category = category
        source.tags = tags
        source.language = language
        source.author_or_org = author_or_org
        source.reviewed_at = now
        source.status = "active"
        source.content_hash = parsed.content_hash
        source.metadata_ = SourceMetadata(
            parser_type=parsed.parser_type,
            parser_version=parsed.parser_version,
            raw_content_hash=parsed.raw_content_hash,
            normalized_content_hash=parsed.content_hash,
            parser_confidence=parsed.parser_confidence,
            skipped_sections=parsed.skipped_sections,
            parent_section_count=len(self._parent_section_hashes_from_parsed(parsed)),
            parent_section_hashes=self._parent_section_hashes_from_parsed(parsed),
            parent_anchor_hashes=self._parent_anchor_hashes_from_parsed(parsed),
            fetch_metadata=parsed.fetch_metadata or {},
        ).model_dump()
        fetch_metadata = parsed.fetch_metadata or {}
        source.external_etag = self._optional_str(fetch_metadata.get("etag"))
        source.external_last_modified = self._parse_http_datetime(fetch_metadata.get("last_modified"))

    async def _search_opensearch(
        self,
        query: str,
        query_embedding: list[float],
        category: str | None,
        top_k: int,
    ) -> list[dict]:
        search_size = max(top_k * 3, top_k)
        keyword_hits = await self.index_service.keyword_search(query, category, search_size)
        vector_hits = await self.index_service.vector_search(query_embedding, category, search_size)
        merged_hits = self._merge_hybrid_hits(keyword_hits, vector_hits)[:top_k]
        chunk_ids = [int(hit["chunk_id"]) for hit in merged_hits if str(hit.get("chunk_id", "")).isdigit()]
        if not chunk_ids:
            return []

        chunk_rows = await self._load_active_chunks(chunk_ids)
        documents: list[dict] = []
        for rank, hit in enumerate(merged_hits, start=1):
            chunk_id = int(hit["chunk_id"])
            row = chunk_rows.get(chunk_id)
            if row is None:
                continue
            chunk, source = row
            documents.append(
                self._build_document(
                    chunk,
                    source,
                    rank=rank,
                    score=hit.get("score"),
                    similarity=hit.get("vector_score"),
                    keyword_score=hit.get("keyword_score"),
                    vector_score=hit.get("vector_score"),
                    index_name=self.settings.RAG_OPENSEARCH_ALIAS,
                    index_version=self.settings.RAG_OPENSEARCH_INDEX,
                )
            )
        return documents

    async def _search_opensearch_keyword(
        self,
        query: str,
        category: str | None,
        top_k: int,
    ) -> list[dict]:
        hits = await self.index_service.keyword_search(query, category, max(top_k * 3, top_k))
        ranked_hits: list[dict] = []
        for rank, hit in enumerate(hits[:top_k], start=1):
            source = hit.get("_source") or {}
            chunk_id = str(source.get("chunk_id") or hit.get("_id") or "")
            if not chunk_id.isdigit():
                continue
            ranked_hits.append(
                {
                    "chunk_id": chunk_id,
                    "score": float(hit.get("_score") or 0.0),
                    "keyword_score": float(hit.get("_score") or 0.0),
                    "rank": rank,
                }
            )

        chunk_rows = await self._load_active_chunks([int(hit["chunk_id"]) for hit in ranked_hits])
        documents: list[dict] = []
        for hit in ranked_hits:
            chunk_id = int(hit["chunk_id"])
            row = chunk_rows.get(chunk_id)
            if row is None:
                continue
            chunk, source = row
            documents.append(
                self._build_document(
                    chunk,
                    source,
                    rank=int(hit["rank"]),
                    score=hit["score"],
                    similarity=None,
                    keyword_score=hit["keyword_score"],
                    vector_score=None,
                    index_name=self.settings.RAG_OPENSEARCH_ALIAS,
                    index_version=self.settings.RAG_OPENSEARCH_INDEX,
                )
            )
        return documents

    async def _search_pgvector(
        self,
        query: str,
        query_embedding: list[float],
        category: str | None,
        top_k: int,
    ) -> list[dict]:
        _ = query
        vec_str = "[" + ",".join(str(x) for x in query_embedding) + "]"
        category_filter = ""
        params: dict[str, object] = {"query_vec": vec_str, "top_k": top_k}
        if category is not None:
            category_filter = "AND c.category = :category"
            params["category"] = category

        stmt = text(
            """
            SELECT c.id, c.source_id, c.title, c.content, c.category,
                   c.tags,
                   s.title AS source_title,
                   s.source_grade,
                   1 - (c.embedding <=> (:query_vec)::vector) AS similarity
            FROM rag_chunks c
            JOIN rag_sources s ON s.id = c.source_id
            WHERE c.status = 'active'
              AND s.status = 'active'
              {category_filter}
            ORDER BY c.embedding <=> (:query_vec)::vector
            LIMIT :top_k
            """.format(category_filter=category_filter)
        )
        rows = (await self.db.execute(stmt, params)).mappings().all()
        return [
            {
                "chunk_id": int(row["id"]),
                "source_id": int(row["source_id"]),
                "title": str(row["title"]),
                "source_title": str(row["source_title"]),
                "content": str(row["content"]),
                "category": str(row["category"]),
                "tags": list(row["tags"] or []),
                "source_grade": str(row["source_grade"]),
                "rank": idx,
                "score": float(row["similarity"]),
                "similarity": float(row["similarity"]),
                "keyword_score": None,
                "vector_score": float(row["similarity"]),
                "index_name": None,
                "index_version": None,
            }
            for idx, row in enumerate(rows, start=1)
        ]

    async def _load_active_chunks(self, chunk_ids: list[int]) -> dict[int, tuple[RagChunk, RagSource]]:
        stmt = (
            select(RagChunk, RagSource)
            .join(RagSource, RagSource.id == RagChunk.source_id)
            .where(
                and_(
                    RagChunk.id.in_(chunk_ids),
                    RagChunk.status == "active",
                    RagSource.status == "active",
                )
            )
        )
        rows = (await self.db.execute(stmt)).all()
        return {chunk.id: (chunk, source) for chunk, source in rows}

    async def _load_active_source_chunks(self, source_id: int) -> list[RagChunk]:
        return (
            await self.db.execute(
                select(RagChunk)
                .where(RagChunk.source_id == source_id, RagChunk.status == "active")
                .order_by(RagChunk.chunk_index.asc())
            )
        ).scalars().all()

    async def _save_retrieval_traces(
        self,
        *,
        documents: list[dict],
        user_id: int,
        request_type: str,
        request_id: int | None,
        trace_group_id: str,
        query_audit: RetrievalQueryAudit,
        category: str | None,
        top_k: int,
        search_backend: str,
        search_mode: str,
    ) -> None:
        if not documents:
            self.db.add(
                RagRetrievalTrace(
                    user_id=user_id,
                    request_type=request_type,
                    request_id=request_id,
                    rag_trace_group_id=trace_group_id,
                    query_text=None,
                    query_hash=query_audit.query_hash,
                    query_summary=query_audit.summary,
                    query_policy_version=query_audit.policy_version,
                    query_key_version=query_audit.key_version,
                    query_retention_until=query_audit.retention_until,
                    query_redacted_at=query_audit.redacted_at,
                    category_filter=category,
                    search_backend=search_backend,
                    search_mode=search_mode,
                    index_name=(
                        self.settings.RAG_OPENSEARCH_ALIAS
                        if search_backend.startswith("opensearch")
                        else None
                    ),
                    index_version=(
                        self.settings.RAG_OPENSEARCH_INDEX
                        if search_backend.startswith("opensearch")
                        else None
                    ),
                    top_k=top_k,
                    chunk_id=None,
                    source_id=None,
                    rank=0,
                    score=None,
                    similarity=None,
                    keyword_score=None,
                    vector_score=None,
                    used_in_prompt=False,
                    used_in_response=False,
                    embedding_model=(
                        self._embedding_model_name() if search_mode != "keyword" else None
                    ),
                )
            )
        for idx, document in enumerate(documents, start=1):
            self.db.add(
                RagRetrievalTrace(
                    user_id=user_id,
                    request_type=request_type,
                    request_id=request_id,
                    rag_trace_group_id=trace_group_id,
                    query_text=None,
                    query_hash=query_audit.query_hash,
                    query_summary=query_audit.summary,
                    query_policy_version=query_audit.policy_version,
                    query_key_version=query_audit.key_version,
                    query_retention_until=query_audit.retention_until,
                    query_redacted_at=query_audit.redacted_at,
                    category_filter=category,
                    search_backend=search_backend,
                    search_mode=search_mode,
                    index_name=document.get("index_name"),
                    index_version=document.get("index_version"),
                    top_k=top_k,
                    chunk_id=document.get("chunk_id"),
                    source_id=document.get("source_id"),
                    rank=int(document.get("rank") or idx),
                    score=document.get("score"),
                    similarity=document.get("similarity"),
                    keyword_score=document.get("keyword_score"),
                    vector_score=document.get("vector_score"),
                    used_in_prompt=True,
                    embedding_model=self._embedding_model_name() if search_mode != "keyword" else None,
                )
            )
        await self.db.commit()

    async def _save_pipeline_decision(
        self,
        decision,
        *,
        job_id: int | None = None,
        source_id: int | None = None,
    ) -> None:
        self.db.add(
            RagPipelineDecision(
                job_id=job_id,
                source_id=source_id,
                decision_type=decision.decision_type,
                policy_version=decision.policy_version,
                selected_action=decision.selected_action,
                risk_level=decision.risk_level,
                reason_code=decision.reason_code,
                context=decision.context,
                tradeoffs=decision.tradeoffs,
            )
        )

    def _merge_hybrid_hits(self, keyword_hits: list[dict], vector_hits: list[dict]) -> list[dict]:
        merged: dict[str, dict] = {}

        for rank, hit in enumerate(keyword_hits, start=1):
            source = hit.get("_source") or {}
            chunk_id = str(source.get("chunk_id") or hit.get("_id") or "")
            if not chunk_id:
                continue
            record = merged.setdefault(chunk_id, {"chunk_id": chunk_id, "score": 0.0})
            raw_score = float(hit.get("_score") or 0.0)
            record["keyword_score"] = raw_score
            record["score"] += self.settings.RAG_KEYWORD_WEIGHT / rank

        for rank, hit in enumerate(vector_hits, start=1):
            source = hit.get("_source") or {}
            chunk_id = str(source.get("chunk_id") or hit.get("_id") or "")
            if not chunk_id:
                continue
            record = merged.setdefault(chunk_id, {"chunk_id": chunk_id, "score": 0.0})
            raw_score = float(hit.get("_score") or 0.0)
            record["vector_score"] = raw_score
            record["score"] += self.settings.RAG_VECTOR_WEIGHT / rank

        return sorted(merged.values(), key=lambda item: float(item.get("score") or 0.0), reverse=True)

    def _build_document(
        self,
        chunk: RagChunk,
        source: RagSource,
        *,
        rank: int,
        score: float | None,
        similarity: float | None,
        keyword_score: float | None,
        vector_score: float | None,
        index_name: str | None,
        index_version: str | None,
    ) -> dict:
        return {
            "chunk_id": chunk.id,
            "source_id": source.id,
            "title": chunk.title,
            "source_title": source.title,
            "content": chunk.content,
            "category": chunk.category,
            "tags": list(chunk.tags or []),
            "source_grade": source.source_grade,
            "rank": rank,
            "score": score,
            "similarity": similarity,
            "keyword_score": keyword_score,
            "vector_score": vector_score,
            "index_name": index_name,
            "index_version": index_version,
        }

    def _build_chunk_plans(
        self,
        parsed: ParsedDocument,
        *,
        source_title: str,
        category: str,
        tags: list[str],
        source_grade: str,
        source_version: int,
    ) -> list[ChunkPlan]:
        return self.chunk_planner.build_chunks(
            parsed,
            source_title=source_title,
            category=category,
            tags=tags,
            source_grade=source_grade,
            embedding_model=self._embedding_model_name(),
            embedding_dim=3072,
            source_version=source_version,
        )

    def _index_payload_hash(self, chunk: RagChunk, source: RagSource) -> str:
        return build_index_payload_hash(
            title=chunk.title,
            content_hash=chunk.content_hash,
            category=chunk.category,
            tags=list(chunk.tags or []),
            source_grade=source.source_grade,
            status=chunk.status if source.status == "active" else source.status,
            embedding_input_hash=chunk.embedding_input_hash,
            source_version=chunk.source_version,
        )

    @staticmethod
    def _change_ratio(old_chunks: list[RagChunk], new_plans: list[ChunkPlan]) -> float:
        if not old_chunks:
            return 1.0 if new_plans else 0.0
        old_hashes = {chunk.content_hash for chunk in old_chunks}
        new_hashes = {plan.content_hash for plan in new_plans}
        stable = len(old_hashes.intersection(new_hashes))
        denominator = max(len(old_hashes), len(new_hashes), 1)
        return max(0.0, min(1.0, 1.0 - (stable / denominator)))

    @staticmethod
    def _refresh_decision_context(
        *,
        existing_source: RagSource | None,
        old_chunks: list[RagChunk],
        new_plans: list[ChunkPlan],
        parsed: ParsedDocument,
    ) -> dict[str, object]:
        old_parent_anchors = {
            str((chunk.metadata_ or {}).get("parent_anchor_hash"))
            for chunk in old_chunks
            if (chunk.metadata_ or {}).get("parent_anchor_hash")
        }
        new_parent_anchors = {
            str(plan.metadata.get("parent_anchor_hash"))
            for plan in new_plans
            if plan.metadata.get("parent_anchor_hash")
        }
        old_parent_content = {
            str((chunk.metadata_ or {}).get("parent_anchor_hash")): str((chunk.metadata_ or {}).get("parent_content_hash"))
            for chunk in old_chunks
            if (chunk.metadata_ or {}).get("parent_anchor_hash")
        }
        new_parent_content = {
            str(plan.metadata.get("parent_anchor_hash")): str(plan.metadata.get("parent_content_hash"))
            for plan in new_plans
            if plan.metadata.get("parent_anchor_hash")
        }
        common_parent_anchors = old_parent_anchors.intersection(new_parent_anchors)
        content_changed_sections = sum(
            1 for anchor in common_parent_anchors if old_parent_content.get(anchor) != new_parent_content.get(anchor)
        )
        changed_sections = max(
            len(new_parent_anchors - old_parent_anchors) + content_changed_sections,
            len(old_parent_anchors - new_parent_anchors) + content_changed_sections,
        )
        total_sections = max(len(new_parent_anchors), len(old_parent_anchors), 0)
        section_change_ratio = changed_sections / total_sections if total_sections else 0.0
        fetch_metadata = parsed.fetch_metadata or {}
        previous_metadata = existing_source.metadata_ if existing_source else {}
        previous_fetch = previous_metadata.get("fetch_metadata") if isinstance(previous_metadata, dict) else {}
        if not isinstance(previous_fetch, dict):
            previous_fetch = {}

        return {
            "changed_section_count": changed_sections,
            "total_section_count": total_sections,
            "section_change_ratio": round(section_change_ratio, 4),
            "anchor_lineage_missing": RAGService._anchor_lineage_missing(old_chunks, new_plans),
            "etag_changed": _metadata_changed(previous_fetch.get("etag"), fetch_metadata.get("etag")),
            "last_modified_changed": _metadata_changed(
                previous_fetch.get("last_modified"),
                fetch_metadata.get("last_modified"),
            ),
            "raw_content_hash": fetch_metadata.get("raw_content_hash"),
            "final_url": fetch_metadata.get("final_url"),
            "content_type": fetch_metadata.get("content_type"),
        }

    @staticmethod
    def _estimate_new_embedding_count(old_chunks: list[RagChunk], new_plans: list[ChunkPlan]) -> int:
        old_inputs = {chunk.embedding_input_hash for chunk in old_chunks}
        return sum(1 for plan in new_plans if plan.embedding_input_hash not in old_inputs)

    @staticmethod
    def _strategy_for_parser(parser_type: str) -> str:
        if parser_type == "markdown":
            return "section"
        if parser_type == "html":
            return "hybrid_evidence"
        if parser_type == "pdf_text":
            return "page_paragraph"
        return "paragraph"

    @staticmethod
    def _parent_section_hashes_from_parsed(parsed: ParsedDocument) -> list[str]:
        hashes: list[str] = []
        seen: set[str] = set()
        for section in parsed.sections:
            if section.parent_section_hash and section.parent_section_hash not in seen:
                seen.add(section.parent_section_hash)
                hashes.append(section.parent_section_hash)
        return hashes

    @staticmethod
    def _parent_anchor_hashes_from_parsed(parsed: ParsedDocument) -> list[str]:
        hashes: list[str] = []
        seen: set[str] = set()
        for section in parsed.sections:
            if section.parent_anchor_hash and section.parent_anchor_hash not in seen:
                seen.add(section.parent_anchor_hash)
                hashes.append(section.parent_anchor_hash)
        return hashes

    @staticmethod
    def _anchor_lineage_missing(old_chunks: list[RagChunk], new_plans: list[ChunkPlan]) -> bool:
        if not old_chunks or not new_plans:
            return False
        if not any(plan.metadata.get("parser_type") == "html" for plan in new_plans):
            return False
        old_missing = any(
            not (chunk.metadata_ or {}).get("parent_anchor_hash")
            or not (chunk.metadata_ or {}).get("chunk_anchor_hash")
            for chunk in old_chunks
        )
        new_missing = any(
            not plan.metadata.get("parent_anchor_hash")
            or not plan.metadata.get("chunk_anchor_hash")
            for plan in new_plans
        )
        return old_missing or new_missing

    @staticmethod
    def _optional_str(value: object) -> str | None:
        if value is None:
            return None
        return str(value)

    @staticmethod
    def _parse_http_datetime(value: object) -> datetime | None:
        if not value:
            return None
        try:
            parsed = parsedate_to_datetime(str(value))
        except (TypeError, ValueError, IndexError, OverflowError):
            return None
        if parsed.tzinfo is None:
            return parsed.replace(tzinfo=timezone.utc)
        return parsed.astimezone(timezone.utc)

    @staticmethod
    def _next_refresh_at(
        refresh_policy: str,
        refresh_interval_hours: int | None,
        now: datetime,
    ) -> datetime | None:
        if refresh_policy != "scheduled" or not refresh_interval_hours:
            return None
        return now + timedelta(hours=refresh_interval_hours)

    @staticmethod
    def _latency_ms(started_at: datetime) -> int:
        return int((datetime.now(timezone.utc) - started_at).total_seconds() * 1000)

    def _embedding_model_name(self) -> str:
        return self.settings.AI_EMBEDDING_MODEL.removeprefix("models/")

    @staticmethod
    def _chunk_text(text_value: str, min_size: int = 50, max_size: int = 1000) -> list[str]:
        normalized = normalize_text(text_value)
        if not normalized:
            return []

        paragraphs = [paragraph.strip() for paragraph in normalized.split("\n\n") if paragraph.strip()]
        raw_chunks: list[str] = []
        current = ""

        for paragraph in paragraphs:
            paragraph_chunks = split_over_max(paragraph, max_size)
            for paragraph_chunk in paragraph_chunks:
                if not current:
                    current = paragraph_chunk
                    continue

                candidate = f"{current}\n\n{paragraph_chunk}"
                if len(candidate) <= max_size:
                    current = candidate
                else:
                    raw_chunks.append(current)
                    current = paragraph_chunk

        if current:
            raw_chunks.append(current)

        merged_chunks: list[str] = []
        for chunk in raw_chunks:
            if len(chunk) >= min_size:
                merged_chunks.append(chunk)
                continue

            if merged_chunks and len(f"{merged_chunks[-1]}\n\n{chunk}") <= max_size:
                merged_chunks[-1] = f"{merged_chunks[-1]}\n\n{chunk}"
                continue

            merged_chunks.append(chunk)

        return [chunk.strip() for chunk in merged_chunks if chunk.strip()]

    @staticmethod
    def _split_over_max(text_value: str, max_size: int) -> list[str]:
        return split_over_max(text_value, max_size)

    @staticmethod
    def _hash_text(value: str) -> str:
        return hash_text(value.strip())

    @staticmethod
    def _normalize_tags(tags: list[str] | None) -> list[str]:
        if not tags:
            return []
        return [tag.strip() for tag in tags if tag.strip()]

    @staticmethod
    def _estimate_token_count(value: str) -> int:
        return estimate_token_count(value)


def _metadata_changed(previous: object, current: object) -> bool:
    if previous in {None, ""} and current in {None, ""}:
        return False
    return previous != current
