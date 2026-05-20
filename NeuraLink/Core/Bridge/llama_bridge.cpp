//
//  llama_bridge.cpp
//  NeuraLink
//
//  C++ implementation of the llama_bridge public API.
//  Integrates llama.cpp via its public C API (llama.h).
//
//  Section layout:
//    §1  Includes and internal struct
//    §2  Context lifecycle (create / free / version)
//    §3  Chat template helper
//    §4  Generation helpers (token_to_str, common_prefix_len, n-gram scan)
//    §5  Standard generate loop (KV-prefix reuse + sampler chain)
//    §6  Prompt-lookup decoding (PLD) generate loop
//    §7  Public dispatcher + cancel
//
//  Created by Dedicatus on 29/04/2026.
//

// MARK: - §1 Includes

#include "llama_bridge.h"
#include "llama_bridge_internal.hpp"

#include <chrono>
#include <algorithm>
#include <cstring>
#include <cstdlib>

// MARK: - §2 Context lifecycle

/// Build the default sampler chain: penalties → top_k → top_p → temp → dist.
/// Tuned for conversational quality without runaway randomness.
static llama_sampler* build_default_sampler() {
    auto sparams = llama_sampler_chain_default_params();
    llama_sampler* chain = llama_sampler_chain_init(sparams);
    if (!chain) { return nullptr; }

    llama_sampler_chain_add(chain, llama_sampler_init_penalties(
        /*penalty_last_n=*/64,
        /*penalty_repeat=*/1.1f,
        /*penalty_freq=*/0.0f,
        /*penalty_present=*/0.0f));
    llama_sampler_chain_add(chain, llama_sampler_init_top_k(40));
    llama_sampler_chain_add(chain, llama_sampler_init_top_p(0.9f, 1));
    llama_sampler_chain_add(chain, llama_sampler_init_temp(0.7f));
    llama_sampler_chain_add(chain, llama_sampler_init_dist(0));
    return chain;
}

LlamaBridgeHandle* llama_bridge_create(
    const char* model_path,
    int32_t     n_ctx,
    int32_t     n_threads,
    int32_t     n_gpu_layers,
    int32_t     k_type,
    int32_t     v_type)
{
    llama_backend_init();

    llama_model_params mp = llama_model_default_params();
    mp.n_gpu_layers       = static_cast<int32_t>(n_gpu_layers);

    llama_model* model = llama_model_load_from_file(model_path, mp);
    if (!model) { llama_backend_free(); return nullptr; }

    llama_context_params cp = llama_context_default_params();
    cp.n_ctx           = static_cast<uint32_t>(n_ctx);
    cp.n_threads       = static_cast<uint32_t>(n_threads);
    cp.type_k          = static_cast<enum ggml_type>(k_type);
    cp.type_v          = static_cast<enum ggml_type>(v_type);
    cp.flash_attn_type = LLAMA_FLASH_ATTN_TYPE_ENABLED;

    llama_context* ctx = llama_new_context_with_model(model, cp);
    if (!ctx) {
        llama_free_model(model); llama_backend_free(); return nullptr;
    }

    llama_sampler* sampler = build_default_sampler();
    if (!sampler) {
        llama_free(ctx); llama_free_model(model); llama_backend_free();
        return nullptr;
    }

    auto* handle    = new LlamaBridgeHandle();
    handle->model   = model;
    handle->ctx     = ctx;
    handle->sampler = sampler;
    return handle;
}

void llama_bridge_free(LlamaBridgeHandle* handle) {
    if (!handle) { return; }
    if (handle->sampler) { llama_sampler_free(handle->sampler); }
    if (handle->ctx)     { llama_free(handle->ctx); }
    if (handle->model)   { llama_free_model(handle->model); }
    llama_backend_free();
    delete handle;
}

const char* llama_bridge_version(void) {
    return llama_print_system_info();
}

void llama_bridge_set_prompt_lookup(
    LlamaBridgeHandle* handle, bool enabled, int32_t n, int32_t n_draft)
{
    if (!handle) { return; }
    handle->pld_enabled = enabled;
    if (n > 0)       { handle->pld_n = n; }
    if (n_draft > 0) { handle->pld_n_draft = n_draft; }
}

// MARK: - §3 Chat template

int32_t llama_bridge_apply_chat_template(
    LlamaBridgeHandle* handle,
    const char* const* roles,
    const char* const* contents,
    int32_t            n_messages,
    bool               add_generation_prompt,
    char*              out_buf,
    int32_t            out_buf_size)
{
    if (!handle || !handle->model || !roles || !contents || n_messages <= 0 ||
        !out_buf || out_buf_size <= 0) {
        return -1;
    }
    const char* tmpl = llama_model_chat_template(handle->model, nullptr);

    std::vector<llama_chat_message> messages;
    messages.reserve(static_cast<size_t>(n_messages));
    for (int32_t i = 0; i < n_messages; ++i) {
        messages.push_back({ roles[i], contents[i] });
    }
    return llama_chat_apply_template(
        tmpl, messages.data(), messages.size(),
        add_generation_prompt, out_buf, out_buf_size);
}

// MARK: - §4 Generation helpers

static int token_to_str(llama_model* model, llama_token tok,
                         char* buf, int buf_size) {
    const auto* vocab = llama_model_get_vocab(model);
    return llama_token_to_piece(vocab, tok, buf, buf_size, 0, true);
}

static size_t common_prefix_len(const std::vector<llama_token>& a,
                                const std::vector<llama_token>& b) {
    const size_t n = std::min(a.size(), b.size());
    size_t i = 0;
    while (i < n && a[i] == b[i]) { ++i; }
    return i;
}

/// Tokenises `prompt` into `out`. Resizes on retry. Returns true on success.
static bool tokenise_into(llama_model* model, const char* prompt,
                          std::vector<llama_token>& out) {
    const auto* vocab = llama_model_get_vocab(model);
    out.resize(2048);
    int n = llama_tokenize(vocab, prompt,
                           static_cast<int32_t>(strlen(prompt)),
                           out.data(),
                           static_cast<int32_t>(out.size()),
                           /*add_special=*/true, /*parse_special=*/true);
    if (n < 0) {
        out.resize(static_cast<size_t>(-n));
        n = llama_tokenize(vocab, prompt,
                           static_cast<int32_t>(strlen(prompt)),
                           out.data(),
                           static_cast<int32_t>(out.size()),
                           true, true);
    }
    if (n <= 0) { return false; }
    out.resize(static_cast<size_t>(n));
    return true;
}

/// Sets up the KV cache via prefix reuse and re-prefills only the suffix
/// that wasn't already cached. Returns true on success; on failure both
/// caches are wiped to leave the handle in a clean state.
static bool sync_kv_for_prompt(LlamaBridgeHandle* h,
                               const std::vector<llama_token>& new_tokens) {
    if (new_tokens.empty()) { return false; }

    size_t common = common_prefix_len(h->kv_tokens, new_tokens);
    if (common >= new_tokens.size()) { common = new_tokens.size() - 1; }

    auto* memory = llama_get_memory(h->ctx);
    if (h->kv_tokens.empty() || common == 0) {
        llama_memory_clear(memory, true);
        common = 0;
    } else if (common < h->kv_tokens.size()) {
        llama_memory_seq_rm(memory, 0, static_cast<llama_pos>(common), -1);
    }

    const size_t suffix_len = new_tokens.size() - common;
    const auto prefill_start = std::chrono::steady_clock::now();
    if (suffix_len > 0) {
        llama_batch batch = llama_batch_get_one(
            const_cast<llama_token*>(new_tokens.data() + common),
            static_cast<int32_t>(suffix_len));
        if (llama_decode(h->ctx, batch) != 0) {
            llama_memory_clear(memory, true);
            h->kv_tokens.clear();
            h->last_prefill_reused = 0;
            h->last_prefill_new    = 0;
            h->last_prefill_ms     = 0.0;
            return false;
        }
    }
    const auto prefill_end = std::chrono::steady_clock::now();
    h->last_prefill_reused = static_cast<int32_t>(common);
    h->last_prefill_new    = static_cast<int32_t>(suffix_len);
    h->last_prefill_ms     = std::chrono::duration<double, std::milli>(
        prefill_end - prefill_start).count();
    h->kv_tokens = new_tokens;
    return true;
}

/// Looks for the most recent n-gram match of the trailing `n` tokens of
/// `tokens` and returns the position immediately AFTER that match (i.e. the
/// start of the speculative draft). Returns size_t-max on no match.
///
/// Scans from end-of-context backwards so we prefer recent matches (more
/// likely to extend the same phrase the model is currently generating).
static constexpr size_t kNoMatch = static_cast<size_t>(-1);

static size_t find_pld_match(const std::vector<llama_token>& tokens,
                             int32_t n) {
    if (n <= 0) { return kNoMatch; }
    const size_t un = static_cast<size_t>(n);
    if (tokens.size() < un + 1) { return kNoMatch; }

    const llama_token* needle = tokens.data() + tokens.size() - un;
    // Range to search: positions where a length-n subsequence fits,
    // excluding the trailing copy of `needle` itself.
    const size_t last_start = tokens.size() - un;
    for (size_t i = last_start; i > 0; --i) {
        const size_t start = i - 1;
        if (start + un >= tokens.size()) { continue; }
        if (std::memcmp(tokens.data() + start, needle,
                        un * sizeof(llama_token)) == 0) {
            return start + un;
        }
    }
    return kNoMatch;
}

// MARK: - §5 Standard generate loop

static void generate_standard(LlamaBridgeHandle* h,
                              std::vector<llama_token>& new_tokens,
                              int32_t max_new_tokens,
                              LlamaTokenCallback on_token,
                              LlamaFinishCallback on_finish,
                              void* user_ctx) {
    const auto* vocab = llama_model_get_vocab(h->model);
    char piece_buf[512] = {};

    for (int step = 0; step < max_new_tokens; ++step) {
        if (h->cancel_flag.load()) { break; }

        llama_token next = llama_sampler_sample(h->sampler, h->ctx, -1);
        llama_sampler_accept(h->sampler, next);

        if (llama_vocab_is_eog(vocab, next)) { break; }

        int piece_len = token_to_str(h->model, next, piece_buf, sizeof(piece_buf));
        if (piece_len > 0) {
            piece_buf[piece_len] = '\0';
            if (on_token && !on_token(piece_buf, user_ctx)) { break; }
        }
        h->kv_tokens.push_back(next);

        llama_batch nb = llama_batch_get_one(&next, 1);
        if (llama_decode(h->ctx, nb) != 0) { break; }
    }
    (void)on_finish;
}

// MARK: - §6 Prompt-lookup decoding loop

/// Emits `tok` via the token callback. Returns true to keep going,
/// false to stop (EOG or callback returned false).
static bool pld_emit(LlamaBridgeHandle* h, llama_token tok,
                     LlamaTokenCallback on_token, void* user_ctx,
                     char* piece_buf, int buf_size) {
    const auto* vocab = llama_model_get_vocab(h->model);
    if (llama_vocab_is_eog(vocab, tok)) { return false; }
    int piece_len = token_to_str(h->model, tok, piece_buf, buf_size);
    if (piece_len > 0) {
        piece_buf[piece_len] = '\0';
        if (on_token && !on_token(piece_buf, user_ctx)) { return false; }
    }
    return true;
}

static void generate_pld(LlamaBridgeHandle* h,
                         std::vector<llama_token>& new_tokens,
                         int32_t max_new_tokens,
                         LlamaTokenCallback on_token,
                         LlamaFinishCallback on_finish,
                         void* user_ctx) {
    char piece_buf[512] = {};
    int generated = 0;
    auto* memory = llama_get_memory(h->ctx);

    while (generated < max_new_tokens && !h->cancel_flag.load()) {
        // Count this iteration as a PLD round; we'll bump hits when an
        // n-gram match is actually found below.
        h->last_pld_rounds += 1;
        // 1. Sample seed token from the *current* logits (no speculation yet).
        //    This is the target's normal next-token choice.
        llama_token first = llama_sampler_sample(h->sampler, h->ctx, -1);
        llama_sampler_accept(h->sampler, first);
        if (!pld_emit(h, first, on_token, user_ctx, piece_buf, sizeof(piece_buf))) {
            h->kv_tokens.push_back(first);
            break;
        }
        h->kv_tokens.push_back(first);
        ++generated;

        llama_batch fb = llama_batch_get_one(&first, 1);
        if (llama_decode(h->ctx, fb) != 0) { break; }
        if (generated >= max_new_tokens) { break; }

        // 2. Look for an n-gram match to seed a speculative draft.
        const size_t match_pos = find_pld_match(h->kv_tokens, h->pld_n);
        if (match_pos == kNoMatch) { continue; }

        const int32_t budget = std::min(
            h->pld_n_draft, max_new_tokens - generated);
        const size_t available = h->kv_tokens.size() > match_pos
            ? h->kv_tokens.size() - match_pos : 0;
        const int32_t n_draft = std::min(
            budget, static_cast<int32_t>(available));
        if (n_draft <= 0) { continue; }

        // Copy the draft tokens into a buffer (kv_tokens may reallocate
        // as we push back; we cannot hold an iterator into it).
        std::vector<llama_token> drafts(
            h->kv_tokens.begin() + match_pos,
            h->kv_tokens.begin() + match_pos + n_draft);

        // 3. Verify drafts[0] BEFORE decoding the drafts batch: the target's
        //    prediction for drafts[0]'s position is logits at -1 right now
        //    (i.e. from the `first` decode above). After we decode the
        //    drafts batch, those logits are no longer accessible.
        llama_token target_d1 = llama_sampler_sample(h->sampler, h->ctx, -1);
        if (target_d1 != drafts[0]) {
            // Mismatch on the very first draft: emit target's choice and
            // start fresh next round. No drafts batch needed.
            llama_sampler_accept(h->sampler, target_d1);
            if (!pld_emit(h, target_d1, on_token, user_ctx, piece_buf, sizeof(piece_buf))) {
                h->kv_tokens.push_back(target_d1);
                break;
            }
            h->kv_tokens.push_back(target_d1);
            ++generated;
            llama_batch tdb = llama_batch_get_one(&target_d1, 1);
            if (llama_decode(h->ctx, tdb) != 0) { break; }
            continue;
        }

        // 4. drafts[0] accepted by target. Count this as a PLD hit — at
        //    least one speculative token was usable. Decode the entire
        //    drafts batch with logits enabled at every position so the
        //    verify loop can sample any row. `llama_batch_get_one` would
        //    only enable logits at the last position, which makes
        //    `sample(ctx, row=0)` fail the `batch.logits[0] != true` assert.
        h->last_pld_hits += 1;
        const llama_pos draft_base_pos = static_cast<llama_pos>(h->kv_tokens.size());
        llama_batch db = llama_batch_init(n_draft, /*embd=*/0, /*n_seq_max=*/1);
        for (int i = 0; i < n_draft; ++i) {
            db.token[db.n_tokens]    = drafts[i];
            db.pos[db.n_tokens]      = draft_base_pos + i;
            db.n_seq_id[db.n_tokens] = 1;
            db.seq_id[db.n_tokens][0] = 0;
            db.logits[db.n_tokens]   = true;
            db.n_tokens++;
        }
        if (llama_decode(h->ctx, db) != 0) {
            llama_batch_free(db);
            llama_memory_clear(memory, true);
            h->kv_tokens.clear();
            break;
        }

        // 5. Commit drafts[0] (already accepted via target_d1) and verify
        //    drafts[1..n_draft-1] against the batch logits.
        llama_sampler_accept(h->sampler, drafts[0]);
        if (!pld_emit(h, drafts[0], on_token, user_ctx, piece_buf, sizeof(piece_buf))) {
            h->kv_tokens.push_back(drafts[0]);
            ++generated;
            llama_batch_free(db);
            break;
        }
        h->kv_tokens.push_back(drafts[0]);
        ++generated;
        int accepted = 1;
        bool stop_round = false;

        for (int i = 1; i < n_draft && !stop_round; ++i) {
            // batch.logits[i-1] = target's prediction at position
            // (draft_base_pos + i-1) = candidate for drafts[i].
            const int row = i - 1;
            llama_token t = llama_sampler_sample(h->sampler, h->ctx, row);

            if (t == drafts[i]) {
                llama_sampler_accept(h->sampler, drafts[i]);
                if (!pld_emit(h, drafts[i], on_token, user_ctx, piece_buf, sizeof(piece_buf))) {
                    h->kv_tokens.push_back(drafts[i]);
                    ++generated;
                    stop_round = true;
                    break;
                }
                h->kv_tokens.push_back(drafts[i]);
                ++generated;
                ++accepted;
            } else {
                // Mismatch at drafts[i]. Rewind target KV to remove
                // drafts[accepted..n_draft-1] (which were speculatively
                // decoded but never committed), then decode target's
                // replacement at position draft_base_pos + accepted.
                const llama_pos rewind_pos = draft_base_pos +
                    static_cast<llama_pos>(accepted);
                llama_memory_seq_rm(memory, 0, rewind_pos, -1);

                llama_batch tb = llama_batch_get_one(&t, 1);
                if (llama_decode(h->ctx, tb) != 0) { stop_round = true; break; }
                llama_sampler_accept(h->sampler, t);

                h->kv_tokens.push_back(t);
                ++generated;

                if (!pld_emit(h, t, on_token, user_ctx, piece_buf, sizeof(piece_buf))) {
                    stop_round = true;
                }
                break;
            }
        }

        llama_batch_free(db);
        if (stop_round) { break; }
        // All drafts accepted (when accepted == n_draft): both KV and
        // kv_tokens are already in sync. Next round continues.
    }
    (void)on_finish;
}

// MARK: - §7 Public dispatcher

void llama_bridge_generate(
    LlamaBridgeHandle*  handle,
    const char*         prompt,
    int32_t             max_new_tokens,
    LlamaTokenCallback  on_token,
    LlamaFinishCallback on_finish,
    void*               user_ctx)
{
    if (!handle || !handle->model || !handle->ctx || !handle->sampler) {
        if (on_finish) { on_finish(user_ctx); }
        return;
    }
    handle->cancel_flag.store(false);
    // Reset per-call PLD telemetry. Prefill stats are reset inside
    // sync_kv_for_prompt, so they don't need touching here.
    handle->last_pld_rounds = 0;
    handle->last_pld_hits   = 0;

    std::vector<llama_token> new_tokens;
    if (!tokenise_into(handle->model, prompt, new_tokens)) {
        if (on_finish) { on_finish(user_ctx); }
        return;
    }
    if (!sync_kv_for_prompt(handle, new_tokens)) {
        if (on_finish) { on_finish(user_ctx); }
        return;
    }

    if (handle->pld_enabled) {
        generate_pld(handle, new_tokens, max_new_tokens,
                     on_token, on_finish, user_ctx);
    } else {
        generate_standard(handle, new_tokens, max_new_tokens,
                          on_token, on_finish, user_ctx);
    }
    if (on_finish) { on_finish(user_ctx); }
}

void llama_bridge_cancel(LlamaBridgeHandle* handle) {
    if (handle) { handle->cancel_flag.store(true); }
}

void llama_bridge_prefill(LlamaBridgeHandle* handle, const char* prompt) {
    if (!handle || !handle->model || !handle->ctx || !prompt) { return; }
    handle->cancel_flag.store(false);
    std::vector<llama_token> new_tokens;
    if (!tokenise_into(handle->model, prompt, new_tokens)) { return; }
    // sync_kv_for_prompt assumes the prompt will be followed by at least one
    // more decode step; it leaves `common = size - 1` so the last token's
    // logits are available for sampling. That's also what we want here —
    // generate's subsequent call appends the user turn after this prefix.
    sync_kv_for_prompt(handle, new_tokens);
}

void llama_bridge_get_prefill_stats(
    LlamaBridgeHandle* handle,
    int32_t*           out_reused,
    int32_t*           out_new,
    double*            out_ms)
{
    if (!handle) { return; }
    if (out_reused) { *out_reused = handle->last_prefill_reused; }
    if (out_new)    { *out_new    = handle->last_prefill_new;    }
    if (out_ms)     { *out_ms     = handle->last_prefill_ms;     }
}
