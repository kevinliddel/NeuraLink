//
//  llama_bridge_spec.cpp
//  NeuraLink
//
//  Speculative-decoding implementation (1.5B draft + 7B target). Lives in a
//  separate translation unit from `llama_bridge.cpp` so the working bridge
//  binary is untouched — adding spec is purely additive.
//
//  Algorithm (per round, while not at max_new_tokens and not EOG):
//    1. Draft samples n_draft tokens greedily, advancing its own KV cache.
//    2. Target batch-decodes those n_draft tokens in one shot — roughly
//       1.5× the cost of a single target decode regardless of N, which is
//       where the speedup comes from.
//    3. Walk the drafts: at each position the target sampler picks a token
//       from the appropriate logits row. Match → accept. First mismatch →
//       emit target's token, rewind KV state via llama_memory_seq_rm in
//       both contexts to position cur_pos + i, redecode the replacement.
//    4. If every draft was accepted, the target's logits at the final
//       position become the next-round seed for free.
//
//  Vocab parity is enforced at create-time so we can use the draft's tokens
//  directly in the target without translation. This is why the production
//  pairing is Qwen-2.5-1.5B (draft) + Qwen-2.5-7B (target) — both share the
//  Qwen 2.5 tokenizer. Llama-3.2 can't be the draft for Qwen because the
//  vocabularies differ.
//
//  Created by Dedicatus on 19/05/2026.
//

#include "llama_bridge.h"
#include "llama_bridge_internal.hpp"
#include <llama/llama.h>

#include <atomic>
#include <vector>
#include <algorithm>
#include <cstring>
#include <string>

// MARK: - Internal struct

struct LlamaBridgeSpecHandle {
    llama_model*             target_model    = nullptr;
    llama_context*           target_ctx      = nullptr;
    llama_sampler*           target_sampler  = nullptr;

    llama_model*             draft_model     = nullptr;
    llama_context*           draft_ctx       = nullptr;

    int32_t                  n_draft         = 4;
    std::atomic<bool>        cancel_flag     { false };

    /// Tokens currently materialised in both models' KV caches for seq 0.
    /// Both models advance in lockstep so they share this view.
    std::vector<llama_token> kv_tokens;
};

// MARK: - Sampler builder (duplicated from llama_bridge.cpp on purpose so
//         this translation unit has no link-time dependency on internal
//         symbols of the standard bridge).

static llama_sampler* spec_build_default_sampler() {
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

// MARK: - Lifecycle

LlamaBridgeSpecHandle* llama_bridge_spec_create(
    const char* target_path,
    const char* draft_path,
    int32_t     n_ctx,
    int32_t     n_threads,
    int32_t     n_gpu_layers,
    int32_t     k_type,
    int32_t     v_type,
    int32_t     flash_attn,
    int32_t     n_draft)
{
    llama_backend_init();

    llama_model_params mp = llama_model_default_params();
    mp.n_gpu_layers       = static_cast<int32_t>(n_gpu_layers);

    llama_model* target_model = llama_model_load_from_file(target_path, mp);
    if (!target_model) { llama_backend_free(); return nullptr; }

    llama_model* draft_model = llama_model_load_from_file(draft_path, mp);
    if (!draft_model) {
        llama_model_free(target_model);
        llama_backend_free();
        return nullptr;
    }

    // Vocab parity check — speculative decoding is undefined when the
    // draft's token ids don't mean the same thing in the target's vocab.
    const auto* tv = llama_model_get_vocab(target_model);
    const auto* dv = llama_model_get_vocab(draft_model);
    if (llama_vocab_n_tokens(tv) != llama_vocab_n_tokens(dv)) {
        llama_model_free(draft_model);
        llama_model_free(target_model);
        llama_backend_free();
        return nullptr;
    }

    llama_context_params cp = llama_context_default_params();
    cp.n_ctx           = static_cast<uint32_t>(n_ctx);
    cp.n_threads       = static_cast<uint32_t>(n_threads);
    cp.type_k          = static_cast<enum ggml_type>(k_type);
    cp.type_v          = static_cast<enum ggml_type>(v_type);
    cp.flash_attn_type = static_cast<enum llama_flash_attn_type>(flash_attn);

    llama_context* target_ctx = llama_init_from_model(target_model, cp);
    llama_context* draft_ctx  = llama_init_from_model(draft_model,  cp);
    llama_sampler* sampler    = spec_build_default_sampler();

    if (!target_ctx || !draft_ctx || !sampler) {
        if (sampler)    { llama_sampler_free(sampler); }
        if (target_ctx) { llama_free(target_ctx); }
        if (draft_ctx)  { llama_free(draft_ctx); }
        llama_model_free(draft_model);
        llama_model_free(target_model);
        llama_backend_free();
        return nullptr;
    }

    auto* h            = new LlamaBridgeSpecHandle();
    h->target_model    = target_model;
    h->target_ctx      = target_ctx;
    h->target_sampler  = sampler;
    h->draft_model     = draft_model;
    h->draft_ctx       = draft_ctx;
    h->n_draft         = std::max(1, n_draft);
    return h;
}

void llama_bridge_spec_free(LlamaBridgeSpecHandle* h) {
    if (!h) { return; }
    if (h->target_sampler) { llama_sampler_free(h->target_sampler); }
    if (h->target_ctx)     { llama_free(h->target_ctx); }
    if (h->draft_ctx)      { llama_free(h->draft_ctx); }
    if (h->target_model)   { llama_model_free(h->target_model); }
    if (h->draft_model)    { llama_model_free(h->draft_model); }
    llama_backend_free();
    delete h;
}

int32_t llama_bridge_spec_apply_chat_template(
    LlamaBridgeSpecHandle* h,
    const char* const* roles,
    const char* const* contents,
    int32_t            n_messages,
    bool               add_generation_prompt,
    char*              out_buf,
    int32_t            out_buf_size)
{
    if (!h || !h->target_model || !roles || !contents || n_messages <= 0 ||
        !out_buf || out_buf_size <= 0) {
        return -1;
    }
    const char* tmpl = llama_model_chat_template(h->target_model, nullptr);
    std::vector<llama_chat_message> messages;
    messages.reserve(static_cast<size_t>(n_messages));
    for (int32_t i = 0; i < n_messages; ++i) {
        messages.push_back({ roles[i], contents[i] });
    }
    return llama_chat_apply_template(tmpl, messages.data(), messages.size(),
                                      add_generation_prompt, out_buf, out_buf_size);
}

void llama_bridge_spec_cancel(LlamaBridgeSpecHandle* h) {
    if (h) { h->cancel_flag.store(true); }
}

// MARK: - Generation helpers

static int spec_token_to_str(llama_model* model, llama_token tok,
                              char* buf, int buf_size) {
    const auto* vocab = llama_model_get_vocab(model);
    return llama_token_to_piece(vocab, tok, buf, buf_size, 0, true);
}

static size_t spec_common_prefix_len(const std::vector<llama_token>& a,
                                     const std::vector<llama_token>& b) {
    const size_t n = std::min(a.size(), b.size());
    size_t i = 0;
    while (i < n && a[i] == b[i]) { ++i; }
    return i;
}

/// Greedy argmax over a single logits row. Used by the draft model where
/// speed matters more than creativity.
static llama_token spec_greedy_argmax(const float* logits, int n_vocab) {
    llama_token best = 0;
    float       best_v = logits[0];
    for (int i = 1; i < n_vocab; ++i) {
        if (logits[i] > best_v) { best_v = logits[i]; best = static_cast<llama_token>(i); }
    }
    return best;
}

// MARK: - Generate

void llama_bridge_spec_generate(
    LlamaBridgeSpecHandle* h,
    const char*            prompt,
    int32_t                max_new_tokens,
    LlamaTokenCallback     on_token,
    LlamaFinishCallback    on_finish,
    void*                  user_ctx)
{
    if (!h || !h->target_model || !h->draft_model ||
        !h->target_ctx || !h->draft_ctx || !h->target_sampler) {
        if (on_finish) { on_finish(user_ctx); }
        return;
    }
    h->cancel_flag.store(false);

    const auto* tvocab = llama_model_get_vocab(h->target_model);
    const int   n_vocab = static_cast<int>(llama_vocab_n_tokens(tvocab));

    // Tokenise via target's vocab (draft shares it by the create-time check).
    std::vector<llama_token> new_tokens(2048);
    int n = llama_tokenize(tvocab, prompt, static_cast<int32_t>(strlen(prompt)),
                            new_tokens.data(),
                            static_cast<int32_t>(new_tokens.size()), true, true);
    if (n < 0) {
        new_tokens.resize(static_cast<size_t>(-n));
        n = llama_tokenize(tvocab, prompt, static_cast<int32_t>(strlen(prompt)),
                            new_tokens.data(),
                            static_cast<int32_t>(new_tokens.size()), true, true);
    }
    if (n <= 0) { if (on_finish) { on_finish(user_ctx); } return; }
    new_tokens.resize(static_cast<size_t>(n));

    // KV-prefix reuse, in lockstep across both models.
    auto* target_mem = llama_get_memory(h->target_ctx);
    auto* draft_mem  = llama_get_memory(h->draft_ctx);
    size_t common = spec_common_prefix_len(h->kv_tokens, new_tokens);
    if (common >= new_tokens.size()) { common = new_tokens.size() - 1; }

    if (h->kv_tokens.empty() || common == 0) {
        llama_memory_clear(target_mem, true);
        llama_memory_clear(draft_mem,  true);
        common = 0;
    } else if (common < h->kv_tokens.size()) {
        llama_memory_seq_rm(target_mem, 0, static_cast<llama_pos>(common), -1);
        llama_memory_seq_rm(draft_mem,  0, static_cast<llama_pos>(common), -1);
    }

    const size_t suffix_len = new_tokens.size() - common;
    if (suffix_len > 0) {
        llama_batch tb = llama_batch_get_one(
            new_tokens.data() + common, static_cast<int32_t>(suffix_len));
        if (llama_decode(h->target_ctx, tb) != 0) {
            llama_memory_clear(target_mem, true);
            llama_memory_clear(draft_mem,  true);
            h->kv_tokens.clear();
            if (on_finish) { on_finish(user_ctx); }
            return;
        }
        llama_batch db = llama_batch_get_one(
            new_tokens.data() + common, static_cast<int32_t>(suffix_len));
        if (llama_decode(h->draft_ctx, db) != 0) {
            llama_memory_clear(target_mem, true);
            llama_memory_clear(draft_mem,  true);
            h->kv_tokens.clear();
            if (on_finish) { on_finish(user_ctx); }
            return;
        }
    }
    h->kv_tokens = new_tokens;

    // Speculative decode loop.
    char piece_buf[512] = {};
    std::string utf8_buf;
    int  generated      = 0;
    const int N         = h->n_draft;

    // See llama_bridge.cpp emit_utf8_safe — same byte-stitching rationale.
    // BPE byte-fallback tokens split multi-byte UTF-8 chars across pieces;
    // forwarding each fragment to Swift's String(cString:) produces �.
    auto emit_token = [&](llama_token tok) -> bool {
        if (llama_vocab_is_eog(tvocab, tok)) { return false; }
        int piece_len = spec_token_to_str(h->target_model, tok, piece_buf, sizeof(piece_buf));
        if (piece_len > 0) {
            utf8_buf.append(piece_buf, piece_len);
            const std::size_t safe = utf8_safe_prefix(utf8_buf);
            if (safe > 0) {
                const std::string prefix = utf8_buf.substr(0, safe);
                utf8_buf.erase(0, safe);
                if (on_token && !on_token(prefix.c_str(), user_ctx)) { return false; }
            }
        }
        return true;
    };

    // Forward any trailing bytes at the end of generation. Without this,
    // a final partial UTF-8 character would be dropped entirely.
    auto flush_remaining = [&]() {
        if (!utf8_buf.empty() && on_token) {
            on_token(utf8_buf.c_str(), user_ctx);
            utf8_buf.clear();
        }
    };

    while (generated < max_new_tokens && !h->cancel_flag.load()) {
        const int n_this_round = std::min(N, max_new_tokens - generated);

        // ── Draft phase: n greedy tokens from the small draft model ────
        std::vector<llama_token> drafts;
        drafts.reserve(static_cast<size_t>(n_this_round));
        bool draft_hit_eog = false;
        for (int i = 0; i < n_this_round; ++i) {
            const float* dlogits = llama_get_logits_ith(h->draft_ctx, -1);
            llama_token d = spec_greedy_argmax(dlogits, n_vocab);
            drafts.push_back(d);
            if (llama_vocab_is_eog(tvocab, d)) { draft_hit_eog = true; break; }
            llama_batch db = llama_batch_get_one(&drafts.back(), 1);
            if (llama_decode(h->draft_ctx, db) != 0) { draft_hit_eog = true; break; }
        }
        if (drafts.empty()) { break; }

        // ── Verify drafts[0] BEFORE the target batch decode ─────────────
        // Target's prediction for drafts[0]'s position is logits at -1
        // RIGHT NOW (from the previous round's target decode or the
        // prefill above). After we decode the drafts batch into target,
        // those logits are no longer accessible.
        llama_token target_d0 = llama_sampler_sample(h->target_sampler, h->target_ctx, -1);

        if (target_d0 != drafts[0]) {
            // Mismatch on draft[0]. Decode target's choice into both
            // models so they stay in lockstep, emit, restart round.
            llama_sampler_accept(h->target_sampler, target_d0);
            llama_batch tb0 = llama_batch_get_one(&target_d0, 1);
            if (llama_decode(h->target_ctx, tb0) != 0) { goto end_generate; }
            llama_batch db0 = llama_batch_get_one(&target_d0, 1);
            if (llama_decode(h->draft_ctx,  db0) != 0) { goto end_generate; }
            h->kv_tokens.push_back(target_d0);
            generated += 1;
            if (!emit_token(target_d0)) { goto end_generate; }
            continue;
        }

        // ── drafts[0] accepted. Batch-decode all drafts through target ──
        // Build an explicit batch with logits=true at every position so
        // the verify loop can sample at any row. `llama_batch_get_one`
        // would only flag the last position, making `sample(row=0)`
        // fail with `batch.logits[0] != true` on the assert.
        const llama_pos draft_base_pos = static_cast<llama_pos>(h->kv_tokens.size());
        llama_batch tbatch = llama_batch_init(
            static_cast<int32_t>(drafts.size()), /*embd=*/0, /*n_seq_max=*/1);
        for (int i = 0; i < static_cast<int>(drafts.size()); ++i) {
            tbatch.token[tbatch.n_tokens]    = drafts[i];
            tbatch.pos[tbatch.n_tokens]      = draft_base_pos + i;
            tbatch.n_seq_id[tbatch.n_tokens] = 1;
            tbatch.seq_id[tbatch.n_tokens][0] = 0;
            tbatch.logits[tbatch.n_tokens]   = true;
            tbatch.n_tokens++;
        }
        if (llama_decode(h->target_ctx, tbatch) != 0) {
            llama_batch_free(tbatch);
            llama_memory_clear(target_mem, true);
            llama_memory_clear(draft_mem,  true);
            h->kv_tokens.clear();
            break;
        }

        // ── Commit drafts[0] and verify drafts[1..n-1] ──────────────────
        llama_sampler_accept(h->target_sampler, drafts[0]);
        if (!emit_token(drafts[0])) {
            h->kv_tokens.push_back(drafts[0]);
            generated += 1;
            llama_batch_free(tbatch);
            goto end_generate;
        }
        h->kv_tokens.push_back(drafts[0]);
        generated += 1;
        int accepted = 1;
        bool stop_round = false;

        for (int i = 1; i < static_cast<int>(drafts.size()) && !stop_round; ++i) {
            // batch.logits[i-1] is target's prediction for the position
            // of drafts[i].
            const int row = i - 1;
            llama_token t = llama_sampler_sample(h->target_sampler, h->target_ctx, row);

            if (t == drafts[i]) {
                llama_sampler_accept(h->target_sampler, drafts[i]);
                if (!emit_token(drafts[i])) {
                    h->kv_tokens.push_back(drafts[i]);
                    generated += 1;
                    stop_round = true;
                    break;
                }
                h->kv_tokens.push_back(drafts[i]);
                generated += 1;
                ++accepted;
            } else {
                // Reject. Rewind both KVs to position draft_base_pos+accepted
                // and put target's choice in place of drafts[i].
                const llama_pos rewind_pos = draft_base_pos +
                    static_cast<llama_pos>(accepted);
                llama_memory_seq_rm(target_mem, 0, rewind_pos, -1);
                llama_memory_seq_rm(draft_mem,  0, rewind_pos, -1);

                llama_batch tb1 = llama_batch_get_one(&t, 1);
                if (llama_decode(h->target_ctx, tb1) != 0) {
                    llama_batch_free(tbatch);
                    goto end_generate;
                }
                llama_batch db1 = llama_batch_get_one(&t, 1);
                if (llama_decode(h->draft_ctx, db1) != 0) {
                    llama_batch_free(tbatch);
                    goto end_generate;
                }
                llama_sampler_accept(h->target_sampler, t);

                h->kv_tokens.push_back(t);
                generated += 1;
                if (!emit_token(t)) { stop_round = true; }
                break;
            }
        }

        llama_batch_free(tbatch);
        if (stop_round) { break; }
        if (draft_hit_eog) { break; }
    }

end_generate:
    flush_remaining();
    if (on_finish) { on_finish(user_ctx); }
}
