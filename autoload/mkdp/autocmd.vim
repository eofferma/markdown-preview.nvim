function! mkdp#autocmd#preview_refresh_visual_line(bufnr) abort
  if bufnr('%') != a:bufnr
    return
  endif
  call mkdp#rpc#preview_refresh([line('.'), line('.')])
endfunction

function! mkdp#autocmd#preview_refresh_visual_state(bufnr) abort
  if bufnr('%') != a:bufnr || mode() !=# 'V'
    return
  endif

  let l:start = line('v')
  let l:end = line('.')
  let l:range = [min([l:start, l:end]), max([l:start, l:end])]
  let l:signature = string(l:range)

  if get(b:, 'mkdp_active_line_range_signature', '') ==# l:signature
    return
  endif

  let b:mkdp_active_line_range_signature = l:signature
  call mkdp#rpc#preview_refresh(l:range)
endfunction

" schedule refresh after mode state and visual marks are updated
function! mkdp#autocmd#preview_refresh_soon(bufnr) abort
  if bufnr('%') != a:bufnr
    return
  endif
  let b:mkdp_active_line_range_signature = ''
  call mkdp#rpc#preview_refresh()
endfunction

function! s:init_visual_line_mapping(bufnr) abort
  if !has('nvim') || !empty(maparg('V', 'n'))
    return
  endif

  let b:mkdp_visual_line_mapping = 1
  execute 'nnoremap <silent><buffer> V V<Cmd>call mkdp#autocmd#preview_refresh_visual_line(' . a:bufnr . ')<CR>'
endfunction

" init preview key action
function! mkdp#autocmd#init() abort
  let l:bufnr = bufnr('%')
  call s:init_visual_line_mapping(l:bufnr)
  execute 'augroup MKDP_REFRESH_INIT' . bufnr('%')
    autocmd!
    " refresh autocmd
    if g:mkdp_refresh_slow
      autocmd CursorHold,BufWrite,InsertLeave <buffer> call mkdp#rpc#preview_refresh()
    else
      autocmd CursorHold,CursorHoldI,CursorMoved,CursorMovedI <buffer> call mkdp#rpc#preview_refresh()
    endif
    if exists('##ModeChanged')
      execute 'autocmd ModeChanged *:V call mkdp#autocmd#preview_refresh_visual_line(' . l:bufnr . ')'
      execute 'autocmd ModeChanged V:* call mkdp#autocmd#preview_refresh_soon(' . l:bufnr . ')'
    endif
    if exists('##SafeState')
      execute 'autocmd SafeState * call mkdp#autocmd#preview_refresh_visual_state(' . l:bufnr . ')'
    endif
    " autoclose autocmd
    if g:mkdp_auto_close
      autocmd BufHidden <buffer> call mkdp#rpc#preview_close()
    endif
    " server close autocmd
    autocmd VimLeave * call mkdp#rpc#stop_server()
  augroup END
endfunction

function! mkdp#autocmd#clear_buf() abort
  if get(b:, 'mkdp_visual_line_mapping', 0)
    silent! nunmap <buffer> V
    unlet b:mkdp_visual_line_mapping
  endif
  execute 'autocmd! ' . 'MKDP_REFRESH_INIT' . bufnr('%')
endfunction
