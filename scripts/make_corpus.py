"""Writes bench_cleanup_corpus.json (synthetic, hand-written; no owner data). Run once: python scripts/make_corpus.py"""
import json
from pathlib import Path

DICT = ["Supabase", "Order2Party", "Vektrum", "WooCommerce", "Next.js", "n8n", "Vercel", "Stripe", "MiauCare",
        "PostgreSQL", "Parakeet", "Haiku",
        "super base -> Supabase", "order to party | order two party -> Order2Party", "woo commerce -> WooCommerce",
        "victrum | vector um -> Vektrum", "n eight n -> n8n", "mal care -> MiauCare", "post gress -> PostgreSQL",
        "next js -> Next.js"]

C = [
 ("pt_fillers", "Hum, então, tipo, eu preciso de enviar o relatório ao cliente até sexta, pronto.",
  "Então, eu preciso de enviar o relatório ao cliente até sexta."),
 ("pt_correction", "Marca a reunião para terça não quarta às três da tarde.",
  "Marca a reunião para quarta às três da tarde."),
 ("pt_multi_correction", "Vamos fazer a reunião na segunda, não, na terça, não, na quarta de manhã, com o cliente e com a equipa de desenvolvimento para fechar o âmbito do projeto.",
  "Vamos fazer a reunião na quarta de manhã, com o cliente e com a equipa de desenvolvimento para fechar o âmbito do projeto."),
 ("br_to_ptpt", "Precisamos de falar com a equipe sobre o registro do contato do cliente, porque o fato é que o celular da equipe não está a funcionar bem e isto já se arrasta há várias semanas sem qualquer solução à vista.",
  "Precisamos de falar com a equipa sobre o registo do contacto do cliente, porque o facto é que o telemóvel da equipa não está a funcionar bem e isto já se arrasta há várias semanas sem qualquer solução à vista."),
 ("dict_near_miss", "Hum, nós usámos o super base para a base de dados e o order to party como cliente principal, e depois ligámos tudo ao woo commerce através do n eight n, que corre no vercel.",
  "Nós usámos o Supabase para a base de dados e o Order2Party como cliente principal, e depois ligámos tudo ao WooCommerce através do n8n, que corre no Vercel."),
 ("en_fillers", "So, um, I think we should, like, ship the new checkout on Friday, you know, because the client has been asking for it for weeks, and we have everything ready except the, um, final tests.",
  "So, I think we should ship the new checkout on Friday, because the client has been asking for it for weeks, and we have everything ready except the final tests."),
 ("pt_one_english_word", "Isto está a ficar crazy, mas acho que o workflow novo vai resolver o problema do cliente.",
  "Isto está a ficar crazy, mas acho que o workflow novo vai resolver o problema do cliente."),
 ("mixed_pt_en", "Hum, então o meeting com o cliente ficou marcado para quinta, e eu acho que devíamos preparar o deck e o pricing antes, tipo, para o follow-up correr bem e não termos de improvisar na call.",
  "Então, o meeting com o cliente ficou marcado para quinta, e eu acho que devíamos preparar o deck e o pricing antes, para o follow-up correr bem e não termos de improvisar na call."),
 ("clean_pt", "Vou enviar o orçamento ao cliente amanhã de manhã.",
  "Vou enviar o orçamento ao cliente amanhã de manhã."),
 ("clean_en", "Please send me the updated report before the meeting tomorrow.",
  "Please send me the updated report before the meeting tomorrow."),
 ("command_translate", "Traduz isto para francês, obrigado pela vossa ajuda.",
  "Traduz isto para francês: obrigado pela vossa ajuda."),
 ("pt_long_300", "Hum, então, pronto, eu queria falar sobre o projeto da loja online, porque o cliente pediu-nos para alterar o checkout, tipo, para aceitar mais métodos de pagamento, e eu acho que isso é possível, mas vai demorar mais uns dias, porque temos de testar tudo com calma e falar com o fornecedor antes de pôr em produção, pronto, e depois confirmamos a data final com ele.",
  "Então, eu queria falar sobre o projeto da loja online, porque o cliente pediu-nos para alterar o checkout para aceitar mais métodos de pagamento, e eu acho que isso é possível, mas vai demorar mais uns dias, porque temos de testar tudo com calma e falar com o fornecedor antes de pôr em produção, e depois confirmamos a data final com ele."),
 ("en_long_300", "Um, so the thing is, like, we need to migrate the database before the end of the month, you know, because the old server is getting really slow, and um, the team has already tested the migration script twice in staging, so I think we can, like, go ahead and schedule it for the weekend when nobody is using the system, and then we just monitor everything on Monday.",
  "So the thing is, we need to migrate the database before the end of the month, because the old server is getting really slow, and the team has already tested the migration script twice in staging, so I think we can go ahead and schedule it for the weekend when nobody is using the system, and then we just monitor everything on Monday."),
 ("en_correction", "Let's meet on Tuesday, no, Wednesday at three, and bring the contract.",
  "Let's meet on Wednesday at three, and bring the contract."),
 ("pt_number_correction", "O orçamento são quatro mil euros, não, cinco mil euros, e o prazo é de três semanas, hum, quer dizer, quatro semanas, a contar da data de assinatura do contrato pelo cliente.",
  "O orçamento são cinco mil euros, e o prazo é de quatro semanas, a contar da data de assinatura do contrato pelo cliente."),
 ("pt_fillers_medium", "Pronto, então eu liguei ao fornecedor, tipo, ontem à tarde, e ele disse que a encomenda só chega na próxima semana, mas que vai enviar um email a confirmar tudo.",
  "Então, eu liguei ao fornecedor ontem à tarde, e ele disse que a encomenda só chega na próxima semana, mas que vai enviar um email a confirmar tudo."),
]

out = {"dictionary": DICT, "texts": [{"id": i, "category": c, "raw": r, "reference": ref} for i, (c, r, ref) in enumerate(C)]}
p = Path(__file__).with_name("bench_cleanup_corpus.json")
p.write_text(json.dumps(out, ensure_ascii=False, indent=1) + "\n")
print(len(C), "texts;", sum(len(t[1]) > 150 for t in C), "over 150 chars;", [len(t[1]) for t in C])
